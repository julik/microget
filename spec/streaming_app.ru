require 'fileutils'
require 'rack'

# The test app
class Streamer
  class TestBody
    def each
      File.open("/tmp/streamer_messages.log", "w") do |f|
        25.times do |i|
          sleep 1
          yield "Message number #{i}\n"
          f.puts(i)
          f.flush # Make sure it is on disk
        end
      end
    end
    
    def close
      FileUtils.touch('/tmp/streamer_close.mark')
    end
  end
  
  def self.call(env)
    # The absence of Content-Length will trigger Rack::Chunking into work automatically.
    [200, {'Content-Type' => 'text/plain'}, TestBody.new]
  end
end

class StreamerWithLength < Streamer
  def self.call(env)
    s, h, b = super
    [s, h.merge('Content-Length' => '440'), b]
  end
end

class HugeBody
  def each
    rng = Random.new
    512.times do
      yield(rng.bytes(1024 * 1024))
    end
  end
end

map '/huge-response' do
  run ->(env) {
    [200, {'Content-Length' => (512 * 1024 * 1024).to_s}, HugeBody.new]
  }
end

map '/empty-response' do
  run ->(env) {
    [304, {'Location' => 'http://elsewhere.com'}, []]
  }
end

map '/chunked' do
  use Rack::Chunked
  run Streamer
end

map '/with-content-length' do
  run StreamerWithLength
end

map '/' do
  run ->(env) { [200, {}, ['Yes']]}
end

map '/alive' do
  run ->(env) { [200, {}, ['Yes']]}
end
