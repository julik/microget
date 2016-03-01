require 'uri'
require 'socket'
require 'kgio'

# An no-nonsense, pedal-to-the-metal unbuffered HTTP streaming client for doing GETs of large bodies, fast.
module Microget
  autoload :ServerRunner, File.dirname(__FILE__) + '/microget/server_runner'
  
  VERSION = '2.0.0'
  
  OpenTimeout = Class.new(StandardError)
  ReadTimeout = Class.new(StandardError)
  
  extend self

  HEADER_LIMIT = 1024 * 64
  HEADER_SEPARATOR = "\r\n\r\n"
  STATUS_PAT = /HTTP\/([\d\.]+) (\d+) (.+)$/.freeze # "HTTP/1.1 200 OK"
  SOCKET_TIMEOUT = 3 # After which time to assume that the connection to the server has died
  
  # Executes a GET request to the given URI with the given headers.
  #
  # Reads the status code and the response headers and parses them into a Hash and the numeric
  # status code. Once that is done, it returns the socket so that the caller can read the body.
  # The caller is responsible for closing the socket when done.
  #
  # @param uri[String] the full URI of the request
  # @param timeout[Numeric] the open and read timeout for the socket select()
  # @param request_headers[Hash] all the request headers to send with the request
  # @return [Array<Numeric, Hash, Socket>] the HTTP status code, the header hash and the socket the body can be read from
  def get_status_headers_and_body_socket(uri, open_timeout: SOCKET_TIMEOUT, timeout: SOCKET_TIMEOUT, request_headers: {})
    uri = URI(uri.to_s)
    raise ('Only plain HTTP is supported (%s)' % uri) unless uri.scheme == 'http'
    raise "Unknown host" unless uri.host
    
    # Some reading on what might be usable here:
    # http://www.mikeperham.com/2009/03/15/socket-timeouts-in-ruby/
    # https://spin.atomicobject.com/2013/09/30/socket-connection-timeout-ruby/
    socket = connect(uri.host, uri.port, open_timeout)
    #socket = TCPSocket.new(uri.host, uri.port) #, timeout)
    
    # Note that if you do Socket#write it switches the Socket into the "buffered"
    # mode, and once that happens your non-blocking operations will block, silently.
    # So, syswrite() - not write()!
    socket.syswrite("GET #{uri.request_uri} HTTP/1.1\r\n")
    
    # AWS signs the Host: header, so introducing port 80 into it "just because" is a bad idea
    if uri.port && uri.port.to_i != 80
      socket.syswrite("Host: %s:%d\r\n" % [uri.host, uri.port])
    else
      socket.syswrite("Host: %s\r\n" % uri.host)
    end
    socket.syswrite("Connection: close\r\n") # Do not request keepalive
    
    # Write all the request headers
    request_headers.each { |k, v| socket.syswrite_nonblock("%s: %s\r\n" % [k,v]) }
    
    # Terminate the request
    socket.syswrite("\r\n")
  
    # First read anything that might be related to the headers, up to and including \r\n\r\n.
    # Once that one is encountered - stash the remaining part we have read, and parse the headers
    headers_buf = read_ahead_headers(socket, timeout)
    status_code, header_hash = parse_status_and_headers(headers_buf)
    [status_code, header_hash, socket]
  rescue Exception => e
    socket.close rescue nil
    raise e
  end
  
  # Executes a GET request to the given URI. Will yield the status, header hash and a chunk of the body
  # to the given block.
  #
  # The socket will be read from as long as the block given to the method yields a truthy value.
  # Once the block returns a truthy value (or the HTTP response is read completely) the method
  # will return the number of bytes of the body it did read and terminate.
  #
  # Please pay special attention to the last yielded argument. It is a _live_ buffer, it will
  # be overwritten on the next invocation of the block. If you need to stash it somewhere, you
  # should #dup it for later use. This is done to work _very_ conservatively with the Ruby GC,
  # and to avoid creating an extra String for every socket receive (which is incredibly wasteful).
  #
  # So this:
  #
  #     body_parts = []
  #     perform_get(uri) do | status, header_hash, body_chunk |
  #       body_parts << body_chunk # will not work, all the elements will reference the same String
  #     end
  #
  # might not be doing what you think it does.
  #
  # @param uri[String] the full URI of the request
  # @param request_headers[Hash] all the request headers to send with the request
  # @param chunk_size[Numeric] what size to feed to read() when reading the response from the socket
  # @yield [Array<Numeric, Hash, String>] status code, header hash, mutable buffer with the last chunk.
  # @return [Numeric] the total number of body bytes read from the socket 
  def perform_get(uri, chunk_size: 1024 * 1024 * 5, read_timeout: SOCKET_TIMEOUT, **status_headers_and_body_options)
    status_code, header_hash, socket = get_status_headers_and_body_socket(uri, **status_headers_and_body_options)
    body_bytes_received = 0
    
    # We are using read_nonblock, and it allows a buffer to be passed in.
    # The advantage of passing a buffer is that the same Ruby string is
    # reused for all the reads, and only the string contents gets reallocated.
    # We can reduce GC pressure this way. So let's have one buffer for all chunks,
    # char*-style.
    body_buf = ''
    
    # Yield the status and headers once with an empty response
    # so that the client can bail out of the request even before the body
    # starts to arrive
    return body_bytes_received unless yield(status_code, header_hash, body_buf)
    
    # ...and then just read the body, without any buffering, using a non-blocking read
    while did_receive = _nonblock_buf_fill(socket, chunk_size, body_buf, read_timeout)
      body_bytes_received += body_buf.bytesize
      do_continue = yield(status_code, header_hash, body_buf)
      return body_bytes_received unless do_continue 
    end
    
    body_bytes_received
  ensure
    socket.close if socket && !socket.closed?
  end
  
  private
  
  
  # Parses a large string with CRLF separators within it into a neat Hash of header key=>values.
  def parse_status_and_headers(headers_str)
    status_and_headers = headers_str.split("\r\n")
    status_line = status_and_headers.shift
  
    # TODO: there is no support for repeating headers (like Cookie:)
    header_hash = status_and_headers.each_with_object({}) do | header, h|
      split_at = header.index(':')
      key, value = header[0...split_at], header[(split_at + 1)..-1]
      h[key] = value.strip
    end
    raise "Invalid response status line #{status_line}" unless status_line =~ STATUS_PAT
  
    http_version, status_code, status = $1, $2, $3
    [status_code.to_i, header_hash]
  end

  # Buffer the data from the socket until we encounter the end of the headers (2x CRLF).
  # Do it per byte so we can leave the socket exactly at byte offset 0 of the response body.
  def read_ahead_headers(socket, timeout)
    headers_str = ''
    headers_and_start_of_body = ''
    start_of_body = ''
    
    byte = '' # Slice off extra allocations even here
    while did_read = _nonblock_buf_fill(socket, 1, byte, timeout)
      raise "Nothing was read" if byte.empty?
      raise "Response header size limit reached" if headers_and_start_of_body.bytesize > HEADER_LIMIT
      headers_and_start_of_body << byte
      
      if headers_and_start_of_body[-4..-1] == HEADER_SEPARATOR
        headers_str = headers_and_start_of_body[0...-4]
        return headers_str
      end
    end
    
    raise 'No header terminating \r\n\r\n found in the response'
  end
  
  # Do a nonblocking read from the given IO, putting the received data into the given outbuf
  def _nonblock_buf_fill(sock, n_bytes, outbuf, timeout)
    # So, if you try read_nonblock on a Socket it will NEVER raise EAGAIN,
    # at least in my tests. It will just happily block until something arrives on the wire.
    #
    # Basically this:
    #   result = sock.read_nonblock(n_bytes, outbuf, exception: false)
    # will not work.
    #
    # Also, select() has no timeout on sockets, even though we really really want it to:
    # http://stackoverflow.com/a/9854392/153886
    # So this is where kgio comes into the picture. It DOES support the wait_readable retval,
    # but does not magically give select(2) the power over sockets - so we copy by just counting
    # the time spent in retries.
    started_at = Time.now.to_f
    spent = 0.0
    
    # With great power comes great responsibility.
    # When kgio_tryread encounters a EAGAIN/EWOULDBLOCK, it will
    # clear our buffer with an empty string.
    # Apparently, this is intended behavior, because there is a test for it.
    loop do
      result = sock.kgio_tryread(n_bytes, outbuf)
      if result == :wait_readable
        sleep 0.1
        spent = (Time.now.to_f - started_at)
        raise ReadTimeout if spent > timeout
      else
        # allow kgio to overwrite our buffer
        return result # if EOF, the result will be nil
      end
    end
  end
  
  # Create a TCP socket and set it to a non-blocking mode.
  # https://spin.atomicobject.com/2013/09/30/socket-connection-timeout-ruby/
  def connect(host, port, timeout)
    # Convert the passed host into structures the non-blocking calls
    # can deal with
    addrs = Socket.getaddrinfo(host, nil)
    ip4_addrinfo = addrs.find{|e| e[0] == 'AF_INET'}
    ip4_ip = ip4_addrinfo[2] # use the last one, the first one will be IPv6
    ip4_socktype = :AF_INET
    
    sockaddr = Socket.pack_sockaddr_in(port, ip4_ip)
    
    #(Socket::AF_INET, Socket::SOCK_STREAM, 0)
    # Create a Kgio::Socket instead of the standard one
    Kgio::Socket.new(Socket.const_get(ip4_socktype), Socket::SOCK_STREAM, 0).tap do |socket|
      socket.setsockopt(Socket::IPPROTO_TCP, Socket::TCP_NODELAY, 1)
 
      begin
        # Initiate the socket connection in the background. If it doesn't fail 
        # immediatelyit will raise an IO::WaitWritable (Errno::EINPROGRESS) 
        # indicating the connection is in progress.
        socket.connect_nonblock(sockaddr)
 
      rescue IO::WaitWritable
        # IO.select will block until the socket is writable or the timeout
        # is exceeded - whichever comes first.
        if IO.select(nil, [socket], nil, timeout)
          begin
            # Verify there is now a good connection
            socket.connect_nonblock(sockaddr)
          rescue Errno::EISCONN
            # Good news everybody, the socket is connected!
          rescue
            # An unexpected exception was raised - the connection is no good.
            socket.close
            raise
          end
        else
          # IO.select returns nil when the socket is not ready before timeout 
          # seconds have elapsed
          socket.close
          raise "Connection timeout"
        end
      end
    end
  end
end
