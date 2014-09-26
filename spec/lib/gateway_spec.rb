require 'spec_helper'

RSpec.describe StraightServer::Gateway do

  before(:each) do
    @gateway = StraightServer::GatewayOnConfig.find_by_id(1)
    @order_mock = double("order mock")
    [:id, :gateway=, :save, :to_h, :id=].each { |m| allow(@order_mock).to receive(m) }
  end

  it "checks for signature when creating a new order" do
    @gateway.last_keychain_id = 0
    expect( -> { @gateway.create_order(amount: 1, signature: 'invalid', id: 1) }).to raise_exception(StraightServer::GatewayModule::InvalidSignature)
    expect(@gateway).to receive(:order_for_keychain_id).with(amount: 1, keychain_id: 1).once.and_return(@order_mock)
    @gateway.create_order(amount: 1, signature: hmac_sha1(1, 'secret'), id: 1)
  end

  it "checks md5 signature only if that setting is set ON for a particular gateway" do
    gateway1 = StraightServer::GatewayOnConfig.find_by_id(1)
    gateway2 = StraightServer::GatewayOnConfig.find_by_id(2)
    expect(gateway2).to receive(:order_for_keychain_id).with(amount: 1, keychain_id: 1).once.and_return(@order_mock)
    expect( -> { gateway1.create_order(amount: 1, signature: 'invalid') }).to raise_exception
    expect( -> { gateway2.create_order(amount: 1, signature: 'invalid') }).not_to raise_exception()
  end

  it "doesn't allow nil or empty order id if signature checks are enabled" do
    expect( -> { @gateway.create_order(amount: 1, signature: 'invalid', id: nil) }).to raise_exception(StraightServer::GatewayModule::InvalidOrderId)
    expect( -> { @gateway.create_order(amount: 1, signature: 'invalid', id: '') }).to raise_exception(StraightServer::GatewayModule::InvalidOrderId)
  end

  context "callback url" do

    before(:each) do
      @gateway = StraightServer::GatewayOnConfig.find_by_id(2) # Gateway 2 doesn't require signatures
    end

    before(:each) do
      @response_mock = double("http response mock")
      expect(@response_mock).to receive(:body).once.and_return('body')
      @order = create(:order)
      allow(@order).to receive(:status).and_return(1)
      allow(@order).to receive(:tid).and_return('tid1')
    end

    it "sends a request to the callback_url" do
      expect(@response_mock).to receive(:code).twice.and_return("200")
      expect(Net::HTTP).to receive(:get_response).and_return(@response_mock)
      @gateway.order_status_changed(@order)
    end

    it "keeps sending request according to the callback schedule if there's an error" do
      expect(@response_mock).to receive(:code).twice.and_return("404")
      expect(@gateway).to receive(:sleep).exactly(10).times
      expect(Net::HTTP).to receive(:get_response).exactly(11).times.and_return(@response_mock)
      expect(URI).to receive(:parse).with('http://localhost:3001/payment-callback?' + @order.to_http_params).exactly(11).times
      @gateway.order_status_changed(@order)
    end

    it "signs the callback if gateway has a secret" do
      @gateway = StraightServer::GatewayOnConfig.find_by_id(1) # Gateway 1 requires signatures
      expect(@response_mock).to receive(:code).twice.and_return("200")
      expect(URI).to receive(:parse).with('http://localhost:3000/payment-callback?' + @order.to_http_params + "&signature=#{hmac_sha1(hmac_sha1(@order.id, 'secret'), 'secret')}")
      expect(Net::HTTP).to receive(:get_response).and_return(@response_mock)
      @gateway.order_status_changed(@order)
    end

    it "receives random data in :data params and sends it back in a callback request" do
      @order.data = 'some random data'
      expect(@gateway).to receive(:order_for_keychain_id).with(amount: 1, keychain_id: 1).once.and_return(@order)
      @gateway.create_order(amount: 1, data: 'some random data')
      expect(@response_mock).to receive(:code).twice.and_return("200")
      expect(Net::HTTP).to receive(:get_response).and_return(@response_mock)
      expect(URI).to receive(:parse).with('http://localhost:3001/payment-callback?' + @order.to_http_params + "&data=#{@order.data}")
      @gateway.order_status_changed(@order)
    end

    it "saves callback url response in the order's record in DB" do
      allow(@response_mock).to receive(:code).and_return("200")
      allow(Net::HTTP).to receive(:get_response).and_return(@response_mock)
      @gateway.order_status_changed(@order)
      expect(@order.callback_response).to eq({code: "200", body: "body"}) 
    end

  end

  describe "config based gateway" do

    it "loads all the gateways from the config file and assigns correct attributes" do
      gateway1 = StraightServer::GatewayOnConfig.find_by_id(1)
      gateway2 = StraightServer::GatewayOnConfig.find_by_id(2)
      expect(gateway1).to be_kind_of(StraightServer::GatewayOnConfig)
      expect(gateway2).to be_kind_of(StraightServer::GatewayOnConfig)

      expect(gateway1.pubkey).to eq('xpub-000') 
      expect(gateway1.confirmations_required).to eq(0) 
      expect(gateway1.order_class).to eq("StraightServer::Order") 
      expect(gateway1.name).to eq("default") 

      expect(gateway2.pubkey).to eq('xpub-001') 
      expect(gateway2.confirmations_required).to eq(0) 
      expect(gateway2.order_class).to eq("StraightServer::Order") 
      expect(gateway2.name).to eq("second_gateway") 
    end

    it "saves and retrieves last_keychain_id from the file in the .straight dir" do
      expect(File.read("#{ENV['HOME']}/.straight/default_last_keychain_id").to_i).to eq(0)
      @gateway.increment_last_keychain_id!
      expect(File.read("#{ENV['HOME']}/.straight/default_last_keychain_id").to_i).to eq(1)

      expect(@gateway).to receive(:order_for_keychain_id).with(amount: 1, keychain_id: 2).once.and_return(@order_mock)
      @gateway.create_order(amount: 1, signature: hmac_sha1(1, 'secret'), id: 1)
      expect(File.read("#{ENV['HOME']}/.straight/default_last_keychain_id").to_i).to eq(2)
    end

  end

  describe "db based gateway" do

    before(:each) do
      @gateway = StraightServer::GatewayOnDB.create(
        confirmations_required: 0,
        pubkey:      'xpub-000',
        order_class: 'StraightServer::Order',
        secret:      'secret',
        name:        'default',
        check_signature: true
      )
    end
    
    it "saves and retrieves last_keychain_id from the db" do
      expect(DB[:gateways][:name => 'default'][:last_keychain_id]).to eq(0)
      @gateway.increment_last_keychain_id!
      expect(DB[:gateways][:name => 'default'][:last_keychain_id]).to eq(1)

      expect(@gateway).to receive(:order_for_keychain_id).with(amount: 1, keychain_id: 2).once.and_return(@order_mock)
      @gateway.create_order(amount: 1, signature: hmac_sha1(1, 'secret'), id: 1)
      expect(DB[:gateways][:name => 'default'][:last_keychain_id]).to eq(2)
    end

  end

  def hmac_sha1(key, secret)
    h = HMAC::SHA1.new('secret')
    h << key.to_s
    h.hexdigest
  end

end