defmodule PowAssent.Plug do
  @moduledoc """
  Plug helper methods.

  If you wish to configure PowAssent through the Pow plug interface rather than
  environment config, please add PowAssent config with `:pow_assent` config:

      plug Pow.Plug.Session,
        repo: MyApp.Repo,
        user: MyApp.User,
        pow_assent: [
          http_adapter: PowAssent.HTTPAdapter.Mint,
          json_library: Poison,
          user_identities_context: MyApp.UserIdentities
        ]
  """
  alias Plug.Conn
  alias PowAssent.{Config, Operations}

  @doc """
  Calls the authentication method for the strategy provider.

  A generated redirection URL will be returned.
  """
  @spec authenticate(Conn.t(), binary(), binary()) :: {:ok, binary(), Conn.t()} | {:error. any(), Conn.t()}
  def authenticate(conn, provider, callback_url) do
    {strategy, provider_config} = get_provider_config(conn, provider)

    provider_config
    |> Config.put(:redirect_uri, callback_url)
    |> strategy.authorize_url()
    |> maybe_put_state(conn)
  end

  defp maybe_put_state({:ok, %{url: url, state: state}}, conn) do
    {:ok, url, Plug.Conn.put_private(conn, :pow_assent_state, state)}
  end
  defp maybe_put_state({:ok, %{url: url}}, conn), do: {:ok, url, conn}
  defp maybe_put_state({:error, error}, conn), do: {:error, error, conn}

  @doc """
  Calls the callback method for the strategy provider.

  A user will be created if a user doesn't already exists in connection or for
  the associated user identity. If a matching user identity association doesn't
  exist for the current user, a new user identity is created. Otherwise user is
  authenticated.
  """
  @spec callback(Conn.t(), binary(), map()) :: {:ok, map(), Conn.t()} |
                                               {:error, {:bound_to_different_user | :invalid_user_id_field, map()}, Conn.t()} |
                                               {:error, {:strategy, any()}, Conn.t()} |
                                               {:error, map(), Conn.t()}
  def callback(conn, provider, params) do
    config                      = fetch_config(conn)
    user                        = Pow.Plug.current_user(conn)
    {strategy, provider_config} = get_provider_config(config, provider)

    provider_config
    |> maybe_set_state_config(conn)
    |> strategy.callback(params)
    |> assign_pow_assent_params(conn)
    |> get_or_create_by_identity(provider, user, config)
  end

  defp maybe_set_state_config(config, %{private: %{pow_assent_state: state}}) do
    Config.put(config, :state, state)
  end
  defp maybe_set_state_config(config, _conn), do: config

  defp assign_pow_assent_params({:ok, %{user: params}}, conn) do
    conn = Conn.put_private(conn, :pow_assent_params, params)

    {:ok, params, conn}
  end
  defp assign_pow_assent_params({:error, error}, conn) do
    {:error, {:strategy, error}, conn}
  end

  defp get_or_create_by_identity({:ok, params, conn}, provider, nil, config) do
    provider
    |> Operations.get_user_by_provider_uid(params["uid"], config)
    |> case do
      nil  -> create_user(conn, provider, params, %{})
      user -> {:ok, user, get_mod(config).do_create(conn, user, config)}
    end
  end
  defp get_or_create_by_identity({:ok, params, conn}, provider, user, config) do
    user
    |> Operations.create(provider, params["uid"], config)
    |> case do
      {:ok, _user_identity} -> {:ok, user, conn}
      {:error, changeset}   -> {:error, changeset, conn}
    end
  end
  defp get_or_create_by_identity({:error, error, conn}, _provider, _config, _user) do
    {:error, error, conn}
  end

  @doc """
  Create a user with user identity.
  """
  @spec create_user(Conn.t(), binary(), map(), map()) :: {:ok, map(), Conn.t()} | {:error, map(), Conn.t()}
  def create_user(conn, provider, params, user_id_params) do
    config = fetch_config(conn)
    uid    = params["uid"]

    provider
    |> Operations.create_user(uid, params, user_id_params, config)
    |> case do
      {:ok, user}         -> {:ok, {:new, user}, get_mod(config).do_create(conn, user, config)}
      {:error, changeset} -> {:error, changeset, conn}
    end
  end

  @doc """
  Deletes the associated user identity for the current user and strategy.
  """
  @spec delete_identity(Conn.t(), binary()) :: {:ok, map(), Conn.t()} | {:error, any(), Conn.t()}
  def delete_identity(conn, provider) do
    config = fetch_config(conn)

    conn
    |> Pow.Plug.current_user()
    |> Operations.delete(provider, config)
    |> case do
      {:ok, results}  -> {:ok, results, conn}
      {:error, error} -> {:error, error, conn}
    end
  end

  @doc """
  Lists associated strategy providers for the user.
  """
  @spec providers_for_current_user(Conn.t()) :: [atom()]
  def providers_for_current_user(conn) do
    config = fetch_config(conn)

    conn
    |> Pow.Plug.current_user()
    |> get_all_providers_for_user(config)
    |> Enum.map(&String.to_atom(&1.provider))
  end

  defp get_all_providers_for_user(nil, _config), do: []
  defp get_all_providers_for_user(user, config), do: Operations.all(user, config)

  @doc """
  Lists available strategy providers for connection.
  """
  @spec available_providers(Conn.t() | Config.t()) :: [atom()]
  def available_providers(%Conn{} = conn) do
    conn
    |> fetch_config()
    |> available_providers()
  end
  def available_providers(config) do
    config
    |> Config.get_providers()
    |> Keyword.keys()
  end

  defp fetch_config(conn) do
    config = Pow.Plug.fetch_config(conn)

    config
    |> Keyword.take([:otp_app, :mod, :repo, :user])
    |> Keyword.merge(Keyword.get(config, :pow_assent, []))
  end

  defp get_provider_config(%Conn{} = conn, provider) do
    conn
    |> fetch_config()
    |> get_provider_config(provider)
  end
  defp get_provider_config(config, provider) do
    provider        = String.to_atom(provider)
    config          = Config.get_provider_config(config, provider)
    strategy        = config[:strategy]
    provider_config = Keyword.delete(config, :strategy)

    {strategy, provider_config}
  end

  defp get_mod(config), do: config[:mod]
end
