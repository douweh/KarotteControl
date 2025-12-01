defmodule KarotteControl.DigitalOcean.Registry do
  @moduledoc """
  DigitalOcean Container Registry API client.
  """

  alias KarotteControl.DigitalOcean.Client

  def get do
    case Client.get("/registry") do
      {:ok, %{"registry" => registry}} -> {:ok, registry}
      error -> error
    end
  end

  def get_subscription do
    case Client.get("/registry/subscription") do
      {:ok, %{"subscription" => subscription}} -> {:ok, subscription}
      error -> error
    end
  end

  def list_repositories(registry_name) do
    case Client.get("/registry/#{registry_name}/repositoriesV2") do
      {:ok, %{"repositories" => repos}} -> {:ok, repos}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def list_tags(registry_name, repository_name) do
    case Client.get("/registry/#{registry_name}/repositories/#{repository_name}/tags") do
      {:ok, %{"tags" => tags}} -> {:ok, tags}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def start_garbage_collection(registry_name) do
    Client.post("/registry/#{registry_name}/garbage-collection", %{})
  end

  def get_garbage_collection(registry_name) do
    case Client.get("/registry/#{registry_name}/garbage-collection") do
      {:ok, %{"garbage_collection" => gc}} -> {:ok, gc}
      error -> error
    end
  end

  def list_garbage_collections(registry_name) do
    case Client.get("/registry/#{registry_name}/garbage-collections") do
      {:ok, %{"garbage_collections" => gcs}} -> {:ok, gcs}
      {:ok, %{}} -> {:ok, []}
      error -> error
    end
  end

  def delete_tag(registry_name, repository_name, tag) do
    Client.delete("/registry/#{registry_name}/repositories/#{repository_name}/tags/#{tag}")
  end

  def delete_manifest(registry_name, repository_name, manifest_digest) do
    Client.delete("/registry/#{registry_name}/repositories/#{repository_name}/digests/#{manifest_digest}")
  end

  @doc """
  Deletes tags older than 1 week, but only if the repository has more than 8 tags.
  Keeps the 8 most recent tags regardless of age.

  Returns `{:ok, deleted_count}` on success or `{:error, reason}` on failure.
  """
  def cleanup_old_tags(registry_name, repository_name, opts \\ []) do
    min_keep = Keyword.get(opts, :min_keep, 8)
    max_age_days = Keyword.get(opts, :max_age_days, 7)

    with {:ok, tags} <- list_tags(registry_name, repository_name) do
      if length(tags) <= min_keep do
        {:ok, 0}
      else
        cutoff = DateTime.add(DateTime.utc_now(), -max_age_days, :day)

        tags_sorted =
          tags
          |> Enum.sort_by(& &1["updated_at"], :desc)

        {_to_keep, candidates} = Enum.split(tags_sorted, min_keep)

        to_delete =
          Enum.filter(candidates, fn tag ->
            case DateTime.from_iso8601(tag["updated_at"]) do
              {:ok, updated_at, _} -> DateTime.before?(updated_at, cutoff)
              _ -> false
            end
          end)

        deleted =
          Enum.reduce(to_delete, 0, fn tag, count ->
            case delete_manifest(registry_name, repository_name, tag["manifest_digest"]) do
              {:ok, _} -> count + 1
              _ -> count
            end
          end)

        {:ok, deleted}
      end
    end
  end
end
