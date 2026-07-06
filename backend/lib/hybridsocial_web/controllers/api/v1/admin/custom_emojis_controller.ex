defmodule HybridsocialWeb.Api.V1.Admin.CustomEmojisController do
  @moduledoc """
  Admin CRUD for the instance-wide custom emoji catalog. The emojis
  surface in the post composer's emoji picker (everyone) and as
  Mastodon-compatible entries on /api/v1/custom_emojis.
  """
  use HybridsocialWeb, :controller

  alias Hybridsocial.Content.Emojis

  def index(conn, _params) do
    emojis = Emojis.list_emojis()
    json(conn, Enum.map(emojis, &serialize/1))
  end

  def create(conn, params) do
    case Emojis.create_emoji(Map.take(params, ~w(shortcode image_url category enabled premium))) do
      {:ok, emoji} ->
        conn |> put_status(:created) |> json(serialize(emoji))

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  def update(conn, %{"id" => id} = params) do
    case Emojis.update_emoji(
           id,
           Map.take(params, ~w(shortcode image_url category enabled premium))
         ) do
      {:ok, emoji} ->
        json(conn, serialize(emoji))

      {:error, :not_found} ->
        conn |> put_status(:not_found) |> json(%{error: "emoji.not_found"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  def delete(conn, %{"id" => id}) do
    case Emojis.delete_emoji(id) do
      {:ok, _} -> conn |> put_status(:no_content) |> send_resp(204, "")
      {:error, :not_found} -> conn |> put_status(:not_found) |> json(%{error: "emoji.not_found"})
    end
  end

  defp serialize(emoji) do
    %{
      id: emoji.id,
      shortcode: emoji.shortcode,
      image_url: emoji.image_url,
      category: emoji.category,
      enabled: emoji.enabled,
      premium: emoji.premium
    }
  end

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
