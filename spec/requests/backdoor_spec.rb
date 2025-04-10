require "spec_helper"

describe "Backdoor Middleware" do
  it "allows signing in using query parameter" do
    user = create(:user)

    get root_path(as: user.to_param)

    expect(cookies["remember_token"]).to eq user.remember_token
  end
end
