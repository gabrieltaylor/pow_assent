defmodule PowAssent.Strategy.OAuth2Test do
  use PowAssent.Test.OAuth2TestCase

  alias PowAssent.{ConfigurationError, CallbackCSRFError, CallbackError, RequestError, Strategy.OAuth2}

  test "authorize_url/2", %{config: config, bypass: bypass} do
    assert {:ok, %{url: url, state: state}} = OAuth2.authorize_url(config)

    refute is_nil(state)
    assert url =~ "http://localhost:#{bypass.port}/oauth/authorize?client_id=&redirect_uri=&response_type=code&state=#{state}"
  end

  describe "callback/2" do
    setup %{config: config} = context do
      config = Keyword.put(config, :user_url, "/api/user")

      {:ok, %{context | config: config}}
    end

    test "normalizes data", %{config: config, callback_params: params, bypass: bypass} do
      expect_oauth2_access_token_request(bypass, [], fn conn ->
        conn = Plug.Conn.fetch_query_params(conn)

        assert conn.params["grant_type"] == "authorization_code"
        assert conn.params["response_type"] == "code"
        assert conn.params["code"] == "test"
        assert conn.params["client_secret"] == "secret"
        assert conn.params["redirect_uri"] == "test"
      end)

      expect_oauth2_user_request(bypass, %{name: "Dan Schultzer", email: "foo@example.com", uid: "1"})

      assert {:ok, %{user: user}} = OAuth2.callback(config, params)
      assert user == %{"email" => "foo@example.com", "name" => "Dan Schultzer", "uid" => "1"}
    end

    test "with redirect error", %{config: config} do
      params = %{"error" => "access_denied", "error_description" => "The user denied the request", "state" => "test"}

      assert {:error, %CallbackError{message: "The user denied the request", error: "access_denied", error_uri: nil}} = OAuth2.callback(config, params)
    end

    test "with invalid state", %{config: config, callback_params: params} do
      params = Map.put(params, "state", "invalid")

      assert {:error, %CallbackCSRFError{}} = OAuth2.callback(config, params)
    end

    test "access token error with 200 response", %{config: config, callback_params: params, bypass: bypass} do
      expect_oauth2_access_token_request(bypass, params: %{"error" => "error", "error_description" => "Error description"})

      assert {:error, %RequestError{error: :unexpected_response}} = OAuth2.callback(config, params)
    end

    test "access token error with 500 response", %{config: config, callback_params: params, bypass: bypass} do
      expect_oauth2_access_token_request(bypass, status_code: 500, params: %{error: "Error"})

      assert {:error, %RequestError{error: :invalid_server_response}} = OAuth2.callback(config, params)
    end

    test "configuration error", %{config: config, callback_params: params, bypass: bypass} do
      config = Keyword.put(config, :user_url, nil)

      expect_oauth2_access_token_request(bypass)

      assert {:error, %ConfigurationError{message: "No user URL set"}} = OAuth2.callback(config, params)
    end

    test "user url connection error", %{config: config, callback_params: params, bypass: bypass} do
      config = Keyword.put(config, :user_url, "http://localhost:8888/api/user")

      expect_oauth2_access_token_request(bypass)

      assert {:error, %PowAssent.RequestError{error: :unreachable}} = OAuth2.callback(config, params)
    end

    test "user url unauthorized access token", %{config: config, callback_params: params, bypass: bypass} do
      expect_oauth2_access_token_request(bypass)
      expect_oauth2_user_request(bypass, %{"error" => "Unauthorized"}, status_code: 401)

      assert {:error, %RequestError{message: "Unauthorized token"}} = OAuth2.callback(config, params)
    end
  end
end
