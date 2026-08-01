defmodule HybridsocialWeb.Api.V1.CustomEmojiController do
  use HybridsocialWeb, :controller

  alias Hybridsocial.Content.Emojis

  # GET /api/v1/custom_emojis
  def index(conn, params) do
    opts =
      case Map.get(params, "category") do
        nil -> []
        category -> [category: category]
      end

    emojis = Emojis.list_emojis(opts)

    conn
    |> put_status(:ok)
    |> HybridsocialWeb.Compat.json(Enum.map(emojis, &serialize_emoji/1), :emojis)
  end

  # This endpoint is read before a client has a token, so the compat layer
  # can't infer the dialect from the session. Emit both spellings — `url` /
  # `static_url` / `visible_in_picker` are what Mastodon's model requires, and
  # the extra keys cost our own client nothing.
  defp serialize_emoji(emoji) do
    %{
      id: emoji.id,
      shortcode: emoji.shortcode,
      image_url: emoji.image_url,
      url: emoji.image_url,
      static_url: emoji.image_url,
      visible_in_picker: emoji.enabled,
      category: emoji.category,
      enabled: emoji.enabled,
      premium: emoji.premium
    }
  end
end
