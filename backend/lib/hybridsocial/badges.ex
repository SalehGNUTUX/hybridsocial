defmodule Hybridsocial.Badges do
  @moduledoc """
  Computes badges for identities based on their roles.

  Instance badges (admin/moderator/owner) respect the user's show_badge preference.
  Group/Page badges (admin/moderator/owner) are always visible within that context.
  """

  import Ecto.Query
  alias Hybridsocial.Repo
  alias Hybridsocial.Auth.RBAC

  @doc """
  Get instance-level badges for an identity.
  Returns a list of badge maps, respecting show_badge preference.
  """
  def instance_badges(identity) do
    if identity.show_badge == false do
      []
    else
      roles = RBAC.get_roles(identity.id)
      badges = []

      badges =
        cond do
          "owner" in roles -> [%{type: "owner", label: "Owner"} | badges]
          identity.is_admin -> [%{type: "admin", label: "Admin"} | badges]
          true -> badges
        end

      badges =
        if "moderator" in roles do
          [%{type: "moderator", label: "Mod"} | badges]
        else
          badges
        end

      badges =
        if identity.is_bot do
          [%{type: "bot", label: "Bot"} | badges]
        else
          badges
        end

      # Verification tier badge (L1+)
      badges =
        case identity.verification_tier do
          "verified_starter" -> [%{type: "verified_l1", label: "Verified"} | badges]
          "verified_creator" -> [%{type: "verified_l2", label: "Verified"} | badges]
          "verified_pro" -> [%{type: "verified_l3", label: "Verified Pro"} | badges]
          _ -> badges
        end

      Enum.reverse(badges)
    end
  end

  @doc """
  Get the badge for an identity within a group context.
  Always visible — cannot be hidden.
  """
  def group_badge(identity_id, group_id) do
    row =
      Repo.one(
        from(gm in "group_members",
          join: g in "groups",
          on: g.id == gm.group_id,
          where:
            gm.identity_id == type(^identity_id, Ecto.UUID) and
              gm.group_id == type(^group_id, Ecto.UUID) and
              gm.status == "approved",
          select: %{role: gm.role, name: g.name}
        )
      )

    case row do
      %{role: "owner", name: name} -> %{type: "owner", label: "Owner of #{name}"}
      %{role: "admin", name: name} -> %{type: "admin", label: "Admin of #{name}"}
      %{role: "moderator", name: name} -> %{type: "moderator", label: "Mod of #{name}"}
      _ -> nil
    end
  end

  @doc """
  Get the badge for an identity within a page/organization context.
  Always visible — cannot be hidden.
  """
  def page_badge(identity_id, organization_id) do
    # `organizations` uses `identity_id` as its primary key (the row
    # is a 1:1 extension of an identity), so the page's display name
    # lives on the joined identities row, not on `organizations`.
    row =
      Repo.one(
        from(or_ in "organization_roles",
          join: i in "identities",
          on: i.id == or_.organization_id,
          where:
            or_.identity_id == type(^identity_id, Ecto.UUID) and
              or_.organization_id == type(^organization_id, Ecto.UUID),
          select: %{role: or_.role, name: i.display_name, handle: i.handle}
        )
      )

    case row do
      %{role: role, name: name, handle: handle} when role in ["admin", "moderator", "editor"] ->
        scope = if name && name != "", do: name, else: handle
        type = role_to_badge_type(role)
        label = "#{role_label(role)} of #{scope}"
        %{type: type, label: label}

      _ ->
        nil
    end
  end

  defp role_to_badge_type("admin"), do: "admin"
  defp role_to_badge_type("moderator"), do: "moderator"
  defp role_to_badge_type("editor"), do: "editor"

  defp role_label("admin"), do: "Admin"
  defp role_label("moderator"), do: "Mod"
  defp role_label("editor"), do: "Editor"

  @doc """
  Compute all badges for a serialized account on a post.
  Takes identity and optional group_id/page_id from the post context.
  """
  def badges_for_post(identity, opts \\ []) do
    group_id = Keyword.get(opts, :group_id)
    page_id = Keyword.get(opts, :page_id)

    instance = instance_badges(identity)

    context =
      cond do
        group_id ->
          case group_badge(identity.id, group_id) do
            nil -> []
            badge -> [badge]
          end

        page_id ->
          case page_badge(identity.id, page_id) do
            nil -> []
            badge -> [badge]
          end

        true ->
          []
      end

    instance ++ context
  end
end
