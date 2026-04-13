defmodule HybridsocialWeb.MediaProxyController do
  use HybridsocialWeb, :controller

  alias Hybridsocial.Media.MediaProxy

  require Logger

  # Only allow media MIME types through the proxy. A compromised or hostile
  # upstream cannot trick the browser into rendering text/html as an HTML
  # page even if it omits nosniff; anything off-allowlist is forced to
  # application/octet-stream.
  @safe_media_prefixes ["image/", "video/", "audio/"]

  @doc "Proxy a remote media URL through the local server."
  # sobelow_skip ["XSS.SendResp"]
  def show(conn, %{"signature" => signature, "encoded_url" => encoded_url}) do
    with {:ok, remote_url} <- MediaProxy.verify_url(signature, encoded_url),
         :ok <- validate_remote_url(remote_url),
         {:ok, response} <- fetch_remote(remote_url) do
      content_type = sanitize_content_type(get_content_type(response))

      conn
      |> put_resp_header("content-type", content_type)
      |> put_resp_header("cache-control", "public, max-age=86400, immutable")
      |> put_resp_header("x-content-type-options", "nosniff")
      |> put_resp_header("content-security-policy", "default-src 'none'")
      |> send_resp(200, response.body)
    else
      {:error, :invalid_signature} ->
        conn |> put_status(403) |> json(%{error: "Invalid signature"})

      {:error, :invalid_url} ->
        conn |> put_status(400) |> json(%{error: "Invalid URL"})

      {:error, :private_host} ->
        conn |> put_status(403) |> json(%{error: "Forbidden"})

      {:error, reason} ->
        Logger.warning("Media proxy fetch failed: #{inspect(reason)}")
        conn |> put_status(502) |> json(%{error: "Failed to fetch remote media"})
    end
  end

  defp validate_remote_url(url) do
    uri = URI.parse(url)

    cond do
      uri.scheme not in ["http", "https"] ->
        {:error, :invalid_url}

      is_nil(uri.host) or uri.host == "" ->
        {:error, :invalid_url}

      private_host?(uri.host) ->
        {:error, :private_host}

      true ->
        :ok
    end
  end

  defp fetch_remote(url) do
    headers = [
      {"User-Agent", "HybridSocial MediaProxy/0.1.0"},
      {"Accept", "*/*"}
    ]

    case HTTPoison.get(url, headers,
           timeout: 15_000,
           recv_timeout: 15_000,
           max_body_length: 50_000_000,
           follow_redirect: true
         ) do
      {:ok, %{status_code: 200} = response} ->
        {:ok, response}

      {:ok, %{status_code: status}} ->
        {:error, {:http_error, status}}

      {:error, reason} ->
        {:error, reason}
    end
  end

  defp get_content_type(%{headers: headers}) do
    headers
    |> Enum.find(fn {k, _v} -> String.downcase(k) == "content-type" end)
    |> case do
      {_, content_type} -> content_type
      nil -> "application/octet-stream"
    end
  end

  defp sanitize_content_type(content_type) when is_binary(content_type) do
    base = content_type |> String.split(";", parts: 2) |> hd() |> String.downcase()

    if Enum.any?(@safe_media_prefixes, &String.starts_with?(base, &1)) do
      base
    else
      "application/octet-stream"
    end
  end

  defp sanitize_content_type(_), do: "application/octet-stream"

  defp private_host?(host) do
    host in ["localhost", "127.0.0.1", "::1", "0.0.0.0"] or
      String.starts_with?(host, "10.") or
      String.starts_with?(host, "192.168.") or
      Regex.match?(~r/^172\.(1[6-9]|2[0-9]|3[01])\./, host)
  end
end
