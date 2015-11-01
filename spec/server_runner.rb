require 'net/http'

class ServerRunner < Struct.new(:command, :port, :rackup_file_path)
  def command
    super % [port, rackup_file_path]
  end
   
  def start!
    # Boot Puma in a forked process
    @pid = fork do
      $stderr.puts "Spinning up with #{command.inspect}"
      # Do not pollute the RSpec output with the Puma logs,
      # save the stuff to logfiles instead
#      $stdout.reopen(File.open('server_runner_stdout.log' % name, 'a'))
#      $stderr.reopen(File.open('server_runner_stderr.log' % name, 'a'))
      
      # Since we have to do with timing tolerances, having the output drip in ASAP is useful
      $stdout.sync = true
      $stderr.sync = true
      exec(command)
    end
    
    Thread.abort_on_exception = true
    
    Thread.new do
      t = Time.now
      # Wait for Puma to be online, poll the alive URL until it stops responding
      loop do
        sleep 0.5
        begin
          alive_check_url = "http://0.0.0.0:%d/alive" % port
          response = Net::HTTP.get_response(URI(alive_check_url))
          @running = true
          break
        rescue Errno::ECONNREFUSED
          if Time.now - t > 2 # Timeout when starting
            raise "Could not get the server started in 2 seconds, something might be misconfigured"
          end
        end
      end
    end
    
    trap("TERM") { stop! }
  end
  
  def running?
    !!@running
  end
  
  def stop!
    return unless @pid
    
    # Tell the webserver to quit, twice (we do not care if there are running responses)
    %W( TERM TERM KILL ).each {|sig| Process.kill(sig, @pid); sleep 0.5 }
    @pid = nil
  end
end
