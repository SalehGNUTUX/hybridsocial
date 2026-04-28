defmodule HybridsocialWeb.Api.V1.PollController do
  use HybridsocialWeb, :controller

  alias Hybridsocial.Social.Polls
  alias Hybridsocial.Social.{Poll, PollOption, Post}
  alias Hybridsocial.Repo
  import Ecto.Query, only: [from: 2]

  # GET /api/v1/polls/:id
  def show(conn, %{"id" => poll_id}) do
    case Polls.get_poll_by_id(poll_id) do
      nil ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "poll.not_found"})

      poll ->
        conn
        |> put_status(:ok)
        |> json(serialize_poll(poll))
    end
  end

  # POST /api/v1/polls/:id/votes
  def vote(conn, %{"id" => poll_id} = params) do
    identity = conn.assigns.current_identity
    option_ids = Map.get(params, "choices", [])

    case Polls.vote(poll_id, identity.id, option_ids) do
      {:ok, _votes} ->
        # Fan the vote out to the origin instance when the poll lives
        # remote. Mastodon-style: one Create-Note activity per chosen
        # option, with `inReplyTo: question.ap_id` and `name: option.text`.
        # Best-effort — local state is already correct for the voter.
        federate_vote_if_remote(identity, poll_id, option_ids)

        poll = Polls.get_poll_by_id(poll_id)

        conn
        |> put_status(:ok)
        |> json(serialize_poll(poll))

      {:error, :not_found} ->
        conn
        |> put_status(:not_found)
        |> json(%{error: "poll.not_found"})

      {:error, :poll_expired} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "poll.expired"})

      {:error, :invalid_options} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "poll.invalid_options"})

      {:error, :already_voted} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "poll.already_voted"})

      {:error, changeset} ->
        conn
        |> put_status(:unprocessable_entity)
        |> json(%{error: "validation.failed", details: format_errors(changeset)})
    end
  end

  defp serialize_poll(poll) do
    %{
      id: poll.id,
      post_id: poll.post_id,
      multiple_choice: poll.multiple_choice,
      expires_at: poll.expires_at,
      voters_count: poll.voters_count,
      options:
        Enum.map(poll.options, fn opt ->
          %{
            id: opt.id,
            text: opt.text,
            position: opt.position,
            votes_count: opt.votes_count
          }
        end)
    }
  end

  defp federate_vote_if_remote(identity, poll_id, option_ids) do
    # Pull poll → post → check ap_id. Only remote posts have an ap_id
    # outside our base url; everything local handles voting on its own.
    case Repo.one(
           from p in Poll,
             where: p.id == ^poll_id,
             join: post in Post,
             on: post.id == p.post_id,
             preload: [post: :identity]
         ) do
      nil ->
        :ok

      poll ->
        post = poll.post

        if remote_post?(post) and is_binary(post.ap_id) do
          options =
            from(o in PollOption,
              where: o.poll_id == ^poll_id and o.id in ^option_ids
            )
            |> Repo.all()

          identity = Repo.preload(identity, [])

          if identity.private_key do
            Task.Supervisor.start_child(
              Hybridsocial.Federation.DeliveryTaskSupervisor,
              fn ->
                for option <- options do
                  activity =
                    Hybridsocial.Federation.ActivityBuilder.build_poll_vote(
                      identity,
                      post,
                      option
                    )

                  Hybridsocial.Federation.Publisher.publish(activity, identity)
                end
              end
            )
          end
        end

        :ok
    end
  end

  defp remote_post?(%Post{identity: %{ap_actor_url: ap}}) when is_binary(ap) do
    base = HybridsocialWeb.Endpoint.url()
    not String.starts_with?(ap, base)
  end

  defp remote_post?(_), do: false

  defp format_errors(changeset) do
    Ecto.Changeset.traverse_errors(changeset, fn {msg, opts} ->
      Regex.replace(~r"%{(\w+)}", msg, fn _, key ->
        opts |> Keyword.get(String.to_existing_atom(key), key) |> to_string()
      end)
    end)
  end
end
