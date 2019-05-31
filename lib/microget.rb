require 'uri'
require 'socket'

# An no-nonsense, pedal-to-the-metal unbuffered HTTP streaming client for doing GETs of large bodies, fast.
module Microget
  autoload :ServerRunner, File.dirname(__FILE__) + '/microget/server_runner'
  VERSION = '1.1.3'
  
  extend self

  HEADER_LIMIT = 1024 * 64
  HEADER_SEPARATOR = "\r\n\r\n"
  STATUS_PAT = /HTTP\/([\d\.]+) (\d+) (.+)$/ # "HTTP/1.1 200 OK"
  SOCKET_TIMEOUT = 60 * 5 # After which time to assume that the connection to the server has died
  
  # Executes a GET request to the given URI with the given headers.
  #
  # Reads the status code and the response headers and parses them into a Hash and the numeric
  # status code. Once that is done, it returns the socket so that the caller can read the body.
  # The caller is responsible for closing the socket when done.
  #
  # @param uri[String] the full URI of the request
  # @param request_headers[Hash] all the request headers to send with the request
  # @return [Array<Numeric, Hash, Socket>] the HTTP status code, the header hash and the socket the body can be read from
  def get_status_headers_and_body_socket(uri, request_headers: {})
    uri = URI(uri.to_s)
    raise ('Only plain HTTP is supported (%s)' % uri) unless uri.scheme == 'http'
    raise "Unknown host" unless uri.host
    
    # Some reading on what might be usable here:
    # http://www.mikeperham.com/2009/03/15/socket-timeouts-in-ruby/
    socket = TCPSocket.open(uri.host, uri.port || 80)
    socket.write("GET #{uri.request_uri} HTTP/1.1\r\n")
    
    # AWS signs the Host: header, so introducing port 80 into it "just because" is a bad idea
    if uri.port && uri.port.to_i != 80
      socket.write("Host: %s:%d\r\n" % [uri.host, uri.port])
    else
      socket.write("Host: %s\r\n" % uri.host)
    end
    socket.write("Connection: close\r\n") # Do not request keepalive
    
    # Write all the request headers
    request_headers.each { |k, v| socket.write("%s: %s\r\n" % [k,v]) }
    
    # Terminate the request
    socket.write("\r\n")
  
    # First read anything that might be related to the headers, up to and including \r\n\r\n.
    # Once that one is encountered - stash the remaining part we have read, and parse the headers
    headers_buf = read_ahead_headers(socket)
    status_code, header_hash = parse_status_and_headers(headers_buf)
    [status_code, header_hash, socket]
  end
  
  # Executes a GET request to the given URI. Will yield the status, header hash and a chunk of the body
  # to the given block.
  #
  # The socket will be read from as long as the block given to the method yields a truthy value.
  # Once the block returns a truthy value (or the HTTP response is read completely) the method
  # will return the number of bytes of the body it did read and terminate.
  #
  # @param uri[String] the full URI of the request
  # @param request_headers[Hash] all the request headers to send with the request
  # @param chunk_size[Numeric] what size to feed to read() when reading the response from the socket
  # @yield [Array<Numeric, Hash, String>] the status code, the header hash and the chunk of the body data read.
  # @return [Numeric] the total number of body bytes read from the socket 
  def perform_get(uri, request_headers: {}, chunk_size: 1024 * 1024 * 5)
    status_code, header_hash, socket = get_status_headers_and_body_socket(uri, request_headers: request_headers)
    body_bytes_received = 0
    
    # Yield the status and headers once with an empty response
    # so that the client can bail out of the request even before the body
    # starts to arrive
    return body_bytes_received unless yield(status_code, header_hash, '')
    
    # We are using read_nonblock, and it allows a buffer to be passed in.
    # The advantage of passing a buffer is that the same Ruby string is
    # reused for all the reads, and only the string contents gets reallocated.
    # We can reduce GC pressure this way.
    body_buf = ''
    
    # ...and then just read the body, without any buffering, using a non-blocking read
    while !socket.eof?
      begin
        data = socket.read_nonblock(chunk_size, body_buf)
        body_bytes_received += data.bytesize
        continue_reading = yield(status_code, header_hash, body_buf)
        return body_bytes_received unless continue_reading 
      rescue IO::WaitReadable
        IO.select([socket], [], SOCKET_TIMEOUT)
        retry
      end
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
  def read_ahead_headers(socket)
    headers_str = ''
    headers_and_start_of_body = ''
    start_of_body = ''
    
    while byte = socket.read(1) do
      raise "Response header size limit reached" if headers_and_start_of_body.bytesize > HEADER_LIMIT
      headers_and_start_of_body << byte
      
      if headers_and_start_of_body[-4..-1] == HEADER_SEPARATOR
        headers_str = headers_and_start_of_body[0...-4]
        return headers_str
      end
    end
    
    raise 'No header terminating \r\n\r\n found in the response'
  end
end
