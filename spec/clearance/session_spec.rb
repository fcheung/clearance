require 'spec_helper'

describe Clearance::Session do
  before { freeze_time }
  after { unfreeze_time }

  let(:session) { Clearance::Session.new(env_without_remember_token) }
  let(:user) { create(:user) }

  it 'finds a user from a cookie' do
    user = create(:user)
    env = env_with_remember_token(user.remember_token)
    session = Clearance::Session.new(env)

    expect(session).to be_signed_in
    expect(session.current_user).to eq user
  end

  it 'returns nil for an unknown user' do
    env = env_with_remember_token('bogus')
    session = Clearance::Session.new(env)

    expect(session).to be_signed_out
    expect(session.current_user).to be_nil
  end

  it 'returns nil without a remember token' do
    expect(session).to be_signed_out
    expect(session.current_user).to be_nil
  end

  context "with a custom cookie name" do
    it "sets a custom cookie name in the header" do
      Clearance.configuration.cookie_name = "custom_cookie_name"

      session.sign_in user
      session.add_cookie_to_headers

      expect(remember_token_cookie(session, "custom_cookie_name")).to be_present
    end
  end

  context "with signed cookies == false" do
    it "uses cookies.signed" do
      Clearance.configuration.signed_cookie = true

      cookie_jar = {}
      expect(session).to receive(:cookies).and_return(cookie_jar)
      expect(cookie_jar).to receive(:signed).and_return(cookie_jar)

      session.sign_in user
    end
  end

  context "with signed cookies == true" do
    it "uses cookies.signed" do
      Clearance.configuration.signed_cookie = true

      cookie_jar = {}
      expect(session).to receive(:cookies).and_return(cookie_jar)
      expect(cookie_jar).to receive(:signed).and_return(cookie_jar)

      session.sign_in user
    end
  end

  context "with signed cookies == :migrate" do
    before do
      Clearance.configuration.signed_cookie = :migrate
    end

    context "signed cookie exists" do
      it "uses cookies.signed[remember_token]" do
        cookie_jar = { "remember_token" => "signed cookie" }
        expect(session).to receive(:cookies).and_return(cookie_jar)
        expect(cookie_jar).to receive(:signed).and_return(cookie_jar)

        session.sign_in user
      end
    end

    context "signed cookie does not exist yet" do
      it "uses cookies[remember_token] instead" do
        cookie_jar = { "remember_token" => "signed cookie" }
        # first call will try to get the signed cookie
        expect(session).to receive(:cookies).and_return(cookie_jar)
        # ... but signed_cookie doesn't exist
        expect(cookie_jar).to receive(:signed).and_return({})
        # then it attempts to retrieve the unsigned cookie
        expect(session).to receive(:cookies).and_return(cookie_jar)

        session.sign_in user
      end
    end
  end

  describe '#sign_in' do
    it 'sets current_user' do
      user = build(:user)

      session.sign_in user

      expect(session.current_user).to eq user
    end

    context 'with a block' do
      it 'passes the success status to the block when sign in succeeds' do
        success_status = stub_status(Clearance::SuccessStatus, true)
        success_lambda = stub_callable

        session.sign_in build(:user), &success_lambda

        expect(success_lambda).to have_been_called.with(success_status)
      end

      it 'passes the failure status to the block when sign in fails' do
        failure_status = stub_status(Clearance::FailureStatus, false)
        failure_lambda = stub_callable

        session.sign_in nil, &failure_lambda

        expect(failure_lambda).to have_been_called.with(failure_status)
      end

      def stub_status(status_class, success)
        double("status", success?: success).tap do |status|
          allow(status_class).to receive(:new).and_return(status)
        end
      end

      def stub_callable
        lambda {}.tap do |callable|
          allow(callable).to receive(:call)
        end
      end
    end

    context 'with nil argument' do
      it 'assigns current_user' do
        session.sign_in nil

        expect(session.current_user).to be_nil
      end
    end

    context 'with a sign in stack' do

      it 'runs the first guard' do
        guard = stub_sign_in_guard(succeed: true)
        user = build(:user)

        session.sign_in user

        expect(guard).to have_received(:call)
      end

      it 'will not sign in the user if the guard stack fails' do
        stub_sign_in_guard(succeed: false)
        user = build(:user)

        session.sign_in user

        expect(session.instance_variable_get("@cookies")).to be_nil
        expect(session.current_user).to be_nil
      end

      def stub_sign_in_guard(options)
        session_status = stub_status(options.fetch(:succeed))

        double("guard", call: session_status).tap do |guard|
          Clearance.configuration.sign_in_guards << stub_guard_class(guard)
        end
      end

      def stub_default_sign_in_guard
        double("default_sign_in_guard").tap do |sign_in_guard|
          allow(Clearance::DefaultSignInGuard).to receive(:new).
            with(session).
            and_return(sign_in_guard)
        end
      end

      def stub_guard_class(guard)
        double("guard_class").tap do |guard_class|
          allow(guard_class).to receive(:to_s).
            and_return(guard_class)

          allow(guard_class).to receive(:constantize).
            and_return(guard_class)

          allow(guard_class).to receive(:new).
            with(session, stub_default_sign_in_guard).
            and_return(guard)
        end
      end

      def stub_status(success)
        double("status", success?: success)
      end

      after do
        Clearance.configuration.sign_in_guards = []
      end
    end
  end

  context 'if httponly is set' do
    before do
      session.sign_in(user)
    end

    it 'sets a httponly cookie' do
      session.add_cookie_to_headers

      expect(remember_token_cookie(session)[:httponly]).to be_truthy
    end
  end

  context 'if httponly is not set' do
    before do
      Clearance.configuration.httponly = false
      session.sign_in(user)
    end

    it 'sets a standard cookie' do
      session.add_cookie_to_headers

      expect(remember_token_cookie(session)[:httponly]).to be_falsey
    end
  end

  context "if same_site is set" do
    before do
      Clearance.configuration.same_site = :lax
      session.sign_in(user)
    end

    it "sets a same-site cookie" do
      session.add_cookie_to_headers

      expect(remember_token_cookie(session)[:same_site]).to eq(:lax)
    end
  end

  context "if same_site is not set" do
    before do
      session.sign_in(user)
    end

    it "sets a standard cookie" do
      session.add_cookie_to_headers

      expect(remember_token_cookie(session)[:same_site]).to be_nil
    end
  end

  describe 'remember token cookie expiration' do
    context 'default configuration' do
      it 'is set to 1 year from now' do
        user = double("User", remember_token: "123abc")
        session = Clearance::Session.new(env_without_remember_token)
        session.sign_in user
        session.add_cookie_to_headers

        expect(remember_token_cookie(session)[:expires]).to eq(1.year.from_now)
      end
    end

    context 'configured with lambda taking one argument' do
      it 'it can use other cookies to set the value of the expires token' do
        remembered_expires = 12.hours.from_now
        expires_at = ->(cookies) do
          cookies['remember_me'] ? remembered_expires : nil
        end
        with_custom_expiration expires_at do
          user = double("User", remember_token: "123abc")
          environment = env_with_cookies(remember_me: 'true')
          session = Clearance::Session.new(environment)
          session.sign_in user
          session.add_cookie_to_headers
          expect(remember_token_cookie(session)[:expires]).to \
            eq(remembered_expires)
          expect(remember_token_cookie(session)[:value]).to \
            eq(user.remember_token)
        end
      end
    end
  end

  describe 'secure cookie option' do
    context 'when not set' do
      before do
        session.sign_in(user)
      end

      it 'sets a standard cookie' do
        session.add_cookie_to_headers

        expect(remember_token_cookie(session)[:secure]).to be_falsey
      end
    end

    context 'when set' do
      before do
        Clearance.configuration.secure_cookie = true
        session.sign_in(user)
      end

      it 'sets a secure cookie' do
        session.add_cookie_to_headers

        expect(remember_token_cookie(session)[:secure]).to be_truthy
      end
    end
  end

  describe "cookie domain option" do
    context "when set" do
      before do
        Clearance.configuration.cookie_domain = cookie_domain
        session.sign_in(user)
      end

      context "with string" do
        let(:cookie_domain) { ".example.com" }

        it "sets a standard cookie" do
          session.add_cookie_to_headers

          expect(remember_token_cookie(session)[:domain]).to eq(cookie_domain)
        end
      end

      context "with lambda" do
        let(:cookie_domain) { lambda { |_r| ".example.com" } }

        it "sets a standard cookie" do
          session.add_cookie_to_headers

          expect(remember_token_cookie(session)[:domain]).to eq(".example.com")
        end
      end
    end

    context 'when not set' do
      before { session.sign_in(user) }

      it 'sets a standard cookie' do
        session.add_cookie_to_headers

        expect(remember_token_cookie(session)[:domain]).to be_nil
      end
    end
  end

  describe 'cookie path option' do
    context 'when not set' do
      before { session.sign_in(user) }

      it 'sets a standard cookie' do
        session.add_cookie_to_headers

        expect(remember_token_cookie(session)[:domain]).to be_nil
      end
    end

    context 'when set' do
      before do
        Clearance.configuration.cookie_path = '/user'
        session.sign_in(user)
      end

      it 'sets a standard cookie' do
        session.add_cookie_to_headers

        expect(remember_token_cookie(session)[:path]).to eq("/user")
      end
    end
  end

  it 'does not set a remember token when signed out' do
    session = Clearance::Session.new(env_without_remember_token)
    session.add_cookie_to_headers
    expect(remember_token_cookie(session)).to be_nil
  end

  describe "#sign_out" do
    it "signs out a user" do
      user = create(:user)
      old_remember_token = user.remember_token
      env = env_with_remember_token(old_remember_token)
      session = Clearance::Session.new(env)
      cookie_jar = ActionDispatch::Request.new(env).cookie_jar
      expect(cookie_jar.deleted?(:remember_token)).to be false

      session.sign_out

      expect(cookie_jar.deleted?(:remember_token)).to be true
      expect(session.current_user).to be_nil
      expect(user.reload.remember_token).not_to eq old_remember_token
    end

    context "with custom cookie domain" do
      let(:domain) { ".example.com" }

      before do
        Clearance.configuration.cookie_domain = domain
      end

      it "clears cookie" do
        user = create(:user)
        env = env_with_remember_token(
          value: user.remember_token,
          domain: domain,
        )
        session = Clearance::Session.new(env)
        cookie_jar = ActionDispatch::Request.new(env).cookie_jar
        expect(cookie_jar.deleted?(:remember_token, domain: domain)).to be false

        session.sign_out

        expect(cookie_jar.deleted?(:remember_token, domain: domain)).to be true
      end
    end

    context 'with callable cookie domain' do
      it 'clears cookie' do
        domain = '.example.com'
        Clearance.configuration.cookie_domain = ->(_) { domain }
        user = create(:user)
        env = env_with_remember_token(
          value: user.remember_token,
          domain: domain
        )
        session = Clearance::Session.new(env)
        cookie_jar = ActionDispatch::Request.new(env).cookie_jar
        expect(cookie_jar.deleted?(:remember_token, domain: domain)).to be false

        session.sign_out

        expect(cookie_jar.deleted?(:remember_token, domain: domain)).to be true
      end
    end
  end

  # a bit of a hack to get the cookies that ActionDispatch sets inside session
  def remember_token_cookie(session, cookie_name = "remember_token")
    cookies = session.send(:cookies)
    # see https://stackoverflow.com/a/21315095
    set_cookies = cookies.instance_eval <<-RUBY, __FILE__, __LINE__ + 1
      @set_cookies
    RUBY
    set_cookies[cookie_name]
  end

  def env_with_cookies(cookies)
    Rack::MockRequest.env_for '/', 'HTTP_COOKIE' => serialize_cookies(cookies)
  end

  def env_with_remember_token(token)
    env_with_cookies 'remember_token' => token
  end

  def env_without_remember_token
    env_with_cookies({})
  end

  def serialize_cookies(hash)
    header = {}

    hash.each do |key, value|
      Rack::Utils.set_cookie_header! header, key, value
    end

    cookie = header["set-cookie"] || header["Set-Cookie"]
    cookie
  end

  def have_been_called
    have_received(:call)
  end

  def with_custom_expiration(custom_duration)
    Clearance.configuration.cookie_expiration = custom_duration
    yield
  end
end
