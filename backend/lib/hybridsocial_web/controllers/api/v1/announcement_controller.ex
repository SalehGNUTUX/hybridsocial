defmodule HybridsocialWeb.Api.V1.AnnouncementController do
  use HybridsocialWeb, :controller
  import Ecto.Query

  def index(conn, _params) do
    announcements =
      try do
        now = DateTime.utc_now()

        # Explicit ::text cast on id — querying a table-string (not a
        # schema) means Ecto returns the uuid column as a raw 16-byte
        # binary, which Jason refuses to encode. Casting to text makes
        # the payload safely serializable.
        from(a in "announcements",
          where: a.published == true,
          where: is_nil(a.starts_at) or a.starts_at <= ^now,
          where: is_nil(a.ends_at) or a.ends_at >= ^now,
          select: %{
            id: fragment("?::text", a.id),
            content: a.content,
            starts_at: a.starts_at,
            ends_at: a.ends_at
          },
          order_by: [desc: a.inserted_at]
        )
        |> Hybridsocial.Repo.all()
      rescue
        _ -> []
      end

    json(conn, announcements)
  end

  def dismiss(conn, %{"id" => _id}) do
    json(conn, %{ok: true})
  end
end
