require 'net/http'

# A simplistic runner for external web servers within a separate process.
class Microget::ServerRunner < Struct.new(:name, :command, :port, :rackup_file_path)
  SHOULD_CONNECT_WITHIN = 2
  
  def command
    super % [port, rackup_file_path]
  end
  
  # Start the server as a subprocess and store its PID.
  #
  # @param timeout[Fixnum] the number of seconds to wait for the server to boot up 
  # @return [TrueClass] true
  def start!(timeout: SHOULD_CONNECT_WITHIN)
    # Boot Puma in a forked process
    @pid = fork do
      $stderr.puts "Spinning up with #{command.inspect}"
      
      # Do not pollute the test suite output with the Puma logs,
      # save the stuff to logfiles instead
      $stdout.reopen(File.open('server_runner_%s_stdout.log' % name, 'a'))
      $stderr.reopen(File.open('server_runner_%s_stderr.log' % name, 'a'))
      
      # Since we have to do with timing tolerances, having the output drip in ASAP is useful
      $stdout.sync = true
      $stderr.sync = true
      exec(command)
    end
    
    Thread.abort_on_exception = true
    
    t = Time.now
    # Wait for Puma to be online, poll the alive URL until it stops responding
    loop do
      sleep 0.5
      begin
        alive_check_url = "http://0.0.0.0:%d/" % port
        response = Net::HTTP.get_response(URI(alive_check_url))
        @running = true
        break
      rescue Errno::ECONNREFUSED
        if (Time.now - t) > timeout # The server is still not on, bail out
          raise "Could not get the server started in 2 seconds, something might be misconfigured"
        end
      end
    end
    
    trap("TERM") { stop! }
    true
  end
  
  # Tells whether the server is currently running
  #
  # @return [TrueClass, FalseClass]
  def running?
    !!@running
  end
  
  # Stops the server by issuing progressively harsher signals to it's process
  # (in the order of TERM, TERM, KILL).
  #
  # @return [TrueClass]
  def stop!
    return unless @pid
    
    # Tell the webserver to quit, twice (we do not care if there are running responses)
    %W( TERM TERM KILL ).each {|sig| Process.kill(sig, @pid); sleep 0.5 }
    @pid = nil
    @running = false
    true
  end
end
