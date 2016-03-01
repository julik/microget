require_relative 'helper'

describe 'Microget' do
  describe '.get_status_headers_and_body_socket' do
    xit 'returns the status, headers and the socket to read the body from, writes the request to the socket' do
      
      http_response = "HTTP/1.0 200 OK\r\n" +
      "Content-Type:   text/plain\r\n" +
      "\r\n" +
      "Yes!"
      
      # Use a fake TCPSocket substituted with a StringIO
      fake_socket = StringIO.new(http_response)
      request_bytes = []
      allow(fake_socket).to receive(:write) {|bytes| request_bytes << bytes }
      
      expect(TCPSocket).to receive(:open).with('0.0.0.0', 9393) { fake_socket }
      
      alive_check_url = "http://0.0.0.0:9393/alive"
      
      status, headers, socket = Microget.get_status_headers_and_body_socket(alive_check_url)
      
      expect(request_bytes).to eq(["GET /alive HTTP/1.1\r\n", "Host: 0.0.0.0:9393\r\n", "Connection: close\r\n", "\r\n"])
      
      expect(status).to be_kind_of(Fixnum)
      expect(status).to eq(200)
      
      expect(headers).to be_kind_of(Hash)
      expect(headers).not_to be_empty
      expect(headers['Content-Type']).to eq('text/plain')
      
      expect(socket).to eq(fake_socket)
      expect(socket).not_to be_closed
      expect(socket).not_to be_eof
      
      yes = socket.read
      expect(socket).to be_eof
      
      expect(yes).to eq('Yes!')
    end
  end
end
