require 'spec_helper'

RSpec::Matchers.define :fail_with do |message|
  match do |actual|
    actual.redirect? && /\?.*message=#{message}/ === actual.location
  end
end

def post_xml(xml=:example_response)
  post "/auth/saml/callback", {'SAMLResponse' => load_xml(xml)}
end

describe OmniAuth::Strategies::SAML, :type => :strategy do
  include OmniAuth::Test::StrategyTestCase

  let(:auth_hash){ last_request.env['omniauth.auth'] }
  let(:saml_options) do
    {
      :assertion_consumer_service_url     => "http://localhost:9080/auth/saml/callback",
      :idp_sso_target_url                 => "https://idp.sso.example.com/signon/29490",
      :idp_cert_fingerprint               => "C1:59:74:2B:E8:0C:6C:A9:41:0F:6E:83:F6:D1:52:25:45:58:89:FB",
      :idp_sso_target_url_runtime_params  => {:original_param_key => :mapped_param_key},
      :name_identifier_format             => "urn:oasis:names:tc:SAML:1.1:nameid-format:emailAddress",
      :request_attributes                 => [
        { :name => 'email', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Email address' },
        { :name => 'name', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Full name' },
        { :name => 'first_name', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Given name' },
        { :name => 'last_name', :name_format => 'urn:oasis:names:tc:SAML:2.0:attrname-format:basic', :friendly_name => 'Family name' }
      ],
      :attribute_service_name             => 'Required attributes'
    }
  end
  let(:strategy) { [OmniAuth::Strategies::SAML, saml_options] }

  describe 'GET /auth/saml' do
    context 'without idp runtime params present' do
      before do
        get '/auth/saml'
      end

      it 'should get authentication page' do
        last_response.should be_redirect
        last_response.location.should match /https:\/\/idp.sso.example.com\/signon\/29490/
        last_response.location.should match /\?SAMLRequest=/
        last_response.location.should_not match /mapped_param_key/
        last_response.location.should_not match /original_param_key/
      end
    end

    context 'with idp runtime params' do
      before do
        get '/auth/saml', 'original_param_key' => 'original_param_value', 'mapped_param_key' => 'mapped_param_value'
      end

      it 'should get authentication page' do
        last_response.should be_redirect
        last_response.location.should match /https:\/\/idp.sso.example.com\/signon\/29490/
        last_response.location.should match /\?SAMLRequest=/
        last_response.location.should match /\&mapped_param_key=original_param_value/
        last_response.location.should_not match /original_param_key/
      end
    end

    context "when the assertion_consumer_service_url is the default" do
      before :each do
        saml_options[:compress_request] = false
        saml_options.delete(:assertion_consumer_service_url)
      end

      it 'should send the current callback_url as the assertion_consumer_service_url' do
        %w(foo.example.com bar.example.com).each do |host|
          get "https://#{host}/auth/saml"

          last_response.should be_redirect

          location = URI.parse(last_response.location)
          query = Rack::Utils.parse_query location.query
          query.should have_key('SAMLRequest')

          request = REXML::Document.new(Base64.decode64(query['SAMLRequest']))
          request.root.should_not be_nil

          acs = request.root.attributes.get_attribute('AssertionConsumerServiceURL')
          acs.to_s.should == "https://#{host}/auth/saml/callback"
        end
      end
    end
  end

  describe 'POST /auth/saml/callback' do
    subject { last_response }

    let(:xml) { :example_response }

    before :each do
      Time.stub(:now).and_return(Time.utc(2012, 11, 8, 20, 40, 00))
    end

    context "when the response is valid" do
      before :each do
        post_xml
      end

      it "should set the uid to the nameID in the SAML response" do
        auth_hash['uid'].should == '_1f6fcf6be5e13b08b1e3610e7ff59f205fbd814f23'
      end

      it "should set the raw info to all attributes" do
        auth_hash['extra']['raw_info'].all.to_hash.should == {
          'first_name'   => ['Rajiv'],
          'last_name'    => ['Manglani'],
          'email'        => ['user@example.com'],
          'company_name' => ['Example Company'],
          'fingerprint'  => saml_options[:idp_cert_fingerprint]
        }
      end
    end

    context "when fingerprint is empty and there's a fingerprint validator" do
      before :each do
        saml_options.delete(:idp_cert_fingerprint)
        saml_options[:idp_cert_fingerprint_validator] = lambda { |fingerprint| "C1:59:74:2B:E8:0C:6C:A9:41:0F:6E:83:F6:D1:52:25:45:58:89:FB" }
        post_xml
      end

      it "should set the uid to the nameID in the SAML response" do
        auth_hash['uid'].should == '_1f6fcf6be5e13b08b1e3610e7ff59f205fbd814f23'
      end

      it "should set the raw info to all attributes" do
        auth_hash['extra']['raw_info'].all.to_hash.should == {
          'first_name'   => ['Rajiv'],
          'last_name'    => ['Manglani'],
          'email'        => ['user@example.com'],
          'company_name' => ['Example Company'],
          'fingerprint'  => 'C1:59:74:2B:E8:0C:6C:A9:41:0F:6E:83:F6:D1:52:25:45:58:89:FB'
        }
      end
    end

    context "when there is no SAMLResponse parameter" do
      before :each do
        post '/auth/saml/callback'
      end

      it { should fail_with(:invalid_ticket) }
    end

    context "when there is no name id in the XML" do
      before :each do
        post_xml :no_name_id
      end

      it { should fail_with(:invalid_ticket) }
    end

    context "when the fingerprint is invalid" do
      before :each do
        saml_options[:idp_cert_fingerprint] = "00:00:00:00:00:0C:6C:A9:41:0F:6E:83:F6:D1:52:25:45:58:89:FB"
        post_xml
      end

      it { should fail_with(:invalid_ticket) }
    end

    context "when the digest is invalid" do
      before :each do
        post_xml :digest_mismatch
      end

      it { should fail_with(:invalid_ticket) }
    end

    context "when the signature is invalid" do
      before :each do
        post_xml :invalid_signature
      end

      it { should fail_with(:invalid_ticket) }
    end

    context "when response has custom attributes" do
      before :each do
        saml_options[:idp_cert_fingerprint] = "3B:82:F1:F5:54:FC:A8:FF:12:B8:4B:B8:16:61:1D:E4:8E:9B:E2:3C"
        saml_options[:attribute_statements] = {
          email: ["http://schemas.xmlsoap.org/ws/2005/05/identity/claims/emailaddress"],
          first_name: ["http://schemas.xmlsoap.org/ws/2005/05/identity/claims/givenname"],
          last_name: ["http://schemas.xmlsoap.org/ws/2005/05/identity/claims/surname"]
        }
        post_xml :custom_attributes
      end

      it "should obey attribute statements mapping" do
        auth_hash[:info].should == {
          'first_name'   => 'Rajiv',
          'last_name'    => 'Manglani',
          'email'        => 'user@example.com',
          'name'         => nil
        }
      end
    end
  end

  describe 'GET /auth/saml/metadata' do
    before do
      get '/auth/saml/metadata'
    end

    it 'should get SP metadata page' do
      last_response.status.should == 200
      last_response.header["Content-Type"].should == "application/xml"
    end

    it 'should configure attributes consuming service' do
      last_response.body.should match /AttributeConsumingService/
      last_response.body.should match /first_name/
      last_response.body.should match /last_name/
      last_response.body.should match /Required attributes/
    end
  end
end
