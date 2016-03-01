require_relative 'helper'

describe "Microget running against a real server" do
  before :all do
    rack_app = File.expand_path(File.join(__dir__, 'streaming_app.ru'))
    @server = Microget::ServerRunner.new(:puma, "bundle exec puma --port %d %s", 9393, rack_app)
    @server.start!
  end
  
  after :all do
    @server.stop!
  end
  
  describe '.perform_get' do
    
    it 'still yields status and headers with an empty response' do
      uri = 'http://localhost:9393/empty-response'
      expect { |b|
        Microget.perform_get(uri, &b)
      }.to yield_with_args(304, {"Location"=>"http://elsewhere.com", "Connection"=>"close"}, "")
    end
    
    it 'streams 512 megabytes of random data from the server without too much trouble' do
      uri = 'http://localhost:9393/huge-response'
      
      bytes_received = 0
      Microget.perform_get(uri, request_headers: {}, chunk_size: 256) do | status, headers, body_chunk|
        bytes_received += body_chunk.bytesize
      end
      expect(bytes_received).to eq(512 * 1024 * 1024)
    end
    
    it 'fetches from the streaming app on Puma using proper chunking' do
      uri = 'http://localhost:9393/with-content-length'
      
      time_deltas_and_chunks = []
      read_headers = {}
      t = Time.now
      
      # Read in larger chunks - nonblocking read will read what it can and then select() anyway, so the timings
      # should be accurate on the outpue
      Microget.perform_get(uri, request_headers: {}, chunk_size: 256) do | status, headers, body_chunk|
        read_headers.merge!(headers)
        expect(status).to eq(200)
        expect(headers).to have_key('Content-Length')
        expect(body_chunk).to be_kind_of(String)
        time_deltas_and_chunks << [Time.now - t, body_chunk.dup]
        t = Time.now
      end
      
      first_chunk_and_delta = time_deltas_and_chunks.shift
      expect(first_chunk_and_delta[1]).to be_empty # First chunk is empty to allow header/status checks

      time_deltas_and_chunks.each do |(delta, chunk_contents)|
        expect(chunk_contents).to include('Message number ')
        expect(delta).to be_within(0.2).of(1.0) # The server "drips" down one message every second, approximately
      end
    end
    
    it 'raises a ReadTimeout if reads take too long' do
      uri = 'http://localhost:9393/very-slow'
      expect {
        Microget.perform_get(uri, timeout: 0.1, chunk_size: 256) do | status, headers, body_chunk|
          true # Continue reading
        end
      }.to raise_error(Microget::ReadTimeout)
    end
  end
end
