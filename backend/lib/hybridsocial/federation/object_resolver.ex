defmodule Hybridsocial.Federation.ObjectResolver do
  @moduledoc """
  Resolves ActivityPub objects by fetching them from remote servers.
  Caches results in the database and respects instance policies.
  """

  alias Hybridsocial.Federation
  alias Hybridsocial.Federation.ActivityMapper

  require Logger

  @doc """
  Fetches and caches a remote AP object by its ID (URL).
  Returns {:ok, object} or {:error, reason}.
  """
  def resolve(ap_id) when is_binary(ap_id) do
    with :ok <- check_instance_policy(ap_id) do
      fetch_object(ap_id)
    end
  end

  def resolve(_), do: {:error, :invalid_ap_id}

  @doc """
  Fetches and caches a remote actor by AP ID.
  First checks the database for a cached version via Federation context,
  then fetches remotely if needed.
  Returns {:ok, remote_actor} or {:error, reason}.
  """
  def resolve_actor(ap_id) when is_binary(ap_id) do
    with :ok <- check_instance_policy(ap_id) do
      Federation.get_or_fetch_remote_actor(ap_id)
    end
  end

  def resolve_actor(_), do: {:error, :invalid_ap_id}

  @doc """
  Checks whether the domain of the given AP ID is allowed by instance policy.
  """
  def check_instance_policy(ap_id) do
    domain = ActivityMapper.extract_domain(ap_id)

    if domain do
      if Federation.domain_allowed?(domain) do
        :ok
      else
        {:error, :domain_suspended}
      end
    else
      {:error, :invalid_domain}
    end
  end

  # Private

  defp fetch_object(url) do
    # SSRF protection
    with :ok <- Hybridsocial.Security.UrlValidator.validate(url) do
      case Hybridsocial.Federation.SignedFetch.get(url,
             follow_redirect: true,
             max_redirect: 3,
             recv_timeout: 15_000,
             timeout: 15_000
           ) do
        {:ok, %Hybridsocial.HTTP.Response{status_code: status, body: body}}
        when status in 200..299 ->
          case Jason.decode(body) do
            {:ok, object} -> {:ok, object}
            {:error, _} -> {:error, :invalid_json}
          end

        {:ok, %Hybridsocial.HTTP.Response{status_code: 404}} ->
          {:error, :not_found}

        {:ok, %Hybridsocial.HTTP.Response{status_code: 410}} ->
          {:error, :gone}

        {:ok, %Hybridsocial.HTTP.Response{status_code: status}} ->
          Logger.warning("Failed to fetch AP object #{url}: HTTP #{status}")
          {:error, {:http_error, status}}

        {:error, %Hybridsocial.HTTP.Error{reason: reason}} ->
          Logger.warning("Failed to fetch AP object #{url}: #{inspect(reason)}")
          {:error, {:fetch_failed, reason}}
      end
    else
      {:error, reason} -> {:error, {:blocked_url, reason}}
    end
  end
end
