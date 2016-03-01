# microget

An no-nonsense, pedal-to-the-metal unbuffered HTTP streaming client for doing GETs of large or slow responses, _fast._
It is meant for situations when you want to get access to the raw data read from the upstream HTTP server,
and read it in your desired increments, with or without buffering. And for situations where you want to
perform such a request but for some reason want to bail out of it early.

It is a prefect vehicle for writing fast HTTP proxies or download managers. It has very few features, but
the features it does have warrant it's existence.

It currently supports:

* Unbuffered GET requests for a given URL
* Streaming body reads directly from-socket, including syscall-driven reads (splice())
* Early disconnect/close on block return
* Any GET headers

It explicitly __does not support__:

* HTTPS
* Keepalive
* Redirects (you can implement them on top)
* Chunked responses (you can implement them on top as well)

## Usage

To read in chunks of N bytes using non-blocking reads:

    # Read in 5 megabyte chunks (assumes the upstream server is fast and you are connected
    # to it via an almost-local downlink):
    Microget.perform_get('http://files.com/hugefile.bin', chunk_size: 5 * 1024 * 1024) do | status, headers, body_chunk |
      if status != 200
        raise "Whoopsie daisy"
      end
      output << body_chunk # Please read the docs on buffer mutability
      true # Signal Microget that it should continue reading by yielding a truthy value from the block
    end

When using `perform_get` the socket will be closed for you at method return, automatically.
  
If you want to do interesting things to the read socket of the HTTP client, use `get_status_headers_and_body_socket`.
For instance, apply it in a reactor-driven setup such as EventMachine, or pass it to a syscall like `splice()`:

    s, h, read_socket_containing_body = Microget.get_status_headers_and_body_socket('http://files.com/hugefile.bin')
    if s != 200
      read_socket_containing_body.close
      raise "Unexpected status #{s}"
    end
    # Use IO::Splice (will only work on linux) to copy the data via the kernel, bypassing the
    # userspace entirely
    IO::Splice.copy_stream(read_socket_containing_body, client_socket_of_the_webserver)
    ...
    socket.close

## What is it's use?

* Testing streaming web servers, web socket servers and so on  with total buffering control
* Building HTTP reverse proxies
* Testing HTTP throughput
* Performing downloads from trusted HTTP servers with tight IO control

## Dependencies

None at all. Not even Net::HTTP. Well, ok, I lied - it used Net::HTTP for tests, sparingly.

## Contributing to microget
 
* Check out the latest master to make sure the feature hasn't been implemented or the bug hasn't been fixed yet.
* Check out the issue tracker to make sure someone already hasn't requested it and/or contributed it.
* Fork the project.
* Start a feature/bugfix branch.
* Commit and push until you are happy with your contribution.
* Make sure to add tests for it. This is important so I don't break it in a future version unintentionally.
* Please try not to mess with the Rakefile, version, or history. If you want to have your own version, or is otherwise necessary, that is fine, but please isolate to its own commit so I can cherry-pick around it.

## Copyright

Copyright (c) 2015 Julik Tarkhanov. See LICENSE.txt for
further details.

