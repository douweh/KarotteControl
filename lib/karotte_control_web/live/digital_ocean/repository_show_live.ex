defmodule KarotteControlWeb.DigitalOcean.RepositoryShowLive do
  use KarotteControlWeb, :live_view

  alias KarotteControl.DigitalOcean.Registry

  @impl true
  def mount(%{"registry_name" => registry_name, "repository_name" => repository_name}, _session, socket) do
    socket =
      socket
      |> assign(:page_title, repository_name)
      |> assign(:registry_name, registry_name)
      |> assign(:repository_name, repository_name)
      |> assign(:tags, [])
      |> assign(:loading, true)
      |> assign(:error, nil)
      |> assign(:show_cleanup_modal, false)
      |> assign(:cleanup_preview, nil)
      |> assign(:cleanup_in_progress, false)
      |> assign(:cleanup_progress, nil)

    if connected?(socket) do
      send(self(), :load_tags)
    end

    {:ok, socket}
  end

  @impl true
  def handle_info(:load_tags, socket) do
    registry_name = socket.assigns.registry_name
    repository_name = socket.assigns.repository_name

    socket =
      case Registry.list_tags(registry_name, repository_name) do
        {:ok, tags} ->
          socket
          |> assign(:tags, tags)
          |> assign(:loading, false)

        {:error, reason} ->
          socket
          |> assign(:error, inspect(reason))
          |> assign(:loading, false)
      end

    {:noreply, socket}
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class="space-y-6">
      <div class="flex items-center gap-4">
        <.link navigate={~p"/digitalocean/registry"} class="btn btn-ghost btn-sm">
          <.icon name="hero-arrow-left" class="h-4 w-4" /> Back
        </.link>
        <div>
          <h1 class="text-2xl font-bold">{@repository_name}</h1>
          <p class="text-sm text-base-content/60">
            Registry: <span class="font-mono">{@registry_name}</span>
          </p>
        </div>
      </div>

      <%= if @loading do %>
        <div class="flex justify-center py-12">
          <span class="loading loading-spinner loading-lg"></span>
        </div>
      <% end %>

      <%= if @error do %>
        <div role="alert" class="alert alert-error">
          <.icon name="hero-exclamation-circle" class="h-5 w-5" />
          <span>Error: {@error}</span>
        </div>
      <% end %>

      <%= if !@loading and @error == nil do %>
        <div class="card bg-base-100 shadow-md">
          <div class="card-body">
            <div class="flex items-center justify-between mb-4">
              <h2 class="card-title">Tags ({length(@tags)})</h2>
              <div class="flex gap-2">
                <button phx-click="show_cleanup_modal" class="btn btn-sm btn-warning">
                  <.icon name="hero-trash" class="h-4 w-4" /> Cleanup Old Tags
                </button>
                <button phx-click="refresh" class="btn btn-sm btn-ghost">
                  <.icon name="hero-arrow-path" class="h-4 w-4" />
                </button>
              </div>
            </div>
            <%= if @tags == [] do %>
              <p class="text-base-content/60">No tags found</p>
            <% else %>
              <div class="overflow-x-auto">
                <table class="table table-zebra">
                  <thead>
                    <tr>
                      <th>Tag</th>
                      <th>Manifest Digest</th>
                      <th>Size</th>
                      <th>Updated</th>
                      <th></th>
                    </tr>
                  </thead>
                  <tbody>
                    <%= for tag <- @tags do %>
                      <tr>
                        <td class="font-mono font-medium">{tag["tag"]}</td>
                        <td class="font-mono text-xs max-w-xs truncate" title={tag["manifest_digest"]}>
                          {String.slice(tag["manifest_digest"] || "", 0..20)}...
                        </td>
                        <td>{format_bytes(tag["compressed_size_bytes"])}</td>
                        <td>{format_date(tag["updated_at"])}</td>
                        <td>
                          <button
                            phx-click="delete_tag"
                            phx-value-tag={tag["tag"]}
                            class="btn btn-xs btn-error btn-ghost"
                            data-confirm={"Are you sure you want to delete tag '#{tag["tag"]}'?"}
                          >
                            <.icon name="hero-trash" class="h-4 w-4" />
                          </button>
                        </td>
                      </tr>
                    <% end %>
                  </tbody>
                </table>
              </div>
            <% end %>
          </div>
        </div>

        <div class="card bg-base-100 shadow-md">
          <div class="card-body">
            <h2 class="card-title">Pull Command</h2>
            <div class="mockup-code">
              <pre><code>docker pull registry.digitalocean.com/{@registry_name}/{@repository_name}:TAG</code></pre>
            </div>
          </div>
        </div>
      <% end %>

      <%= if @show_cleanup_modal do %>
        <div class="modal modal-open">
          <div class="modal-box">
            <h3 class="font-bold text-lg">Cleanup Old Tags</h3>
            <p class="py-4">
              This will delete all tags older than 1 week, keeping at least 8 most recent tags.
            </p>

            <%= if @cleanup_preview do %>
              <div class="bg-base-200 rounded-lg p-4 mb-4">
                <p class="font-medium">Preview:</p>
                <ul class="list-disc list-inside mt-2 text-sm">
                  <li>Total tags: {@cleanup_preview.total}</li>
                  <li>Tags to keep: {@cleanup_preview.to_keep}</li>
                  <li class="text-error font-medium">Tags to delete: {@cleanup_preview.to_delete}</li>
                </ul>
                <%= if @cleanup_preview.to_delete > 0 do %>
                  <div class="mt-3">
                    <p class="text-sm font-medium mb-1">Tags that will be deleted:</p>
                    <div class="max-h-32 overflow-y-auto">
                      <%= for tag <- @cleanup_preview.delete_list do %>
                        <span class="badge badge-error badge-sm mr-1 mb-1">{tag}</span>
                      <% end %>
                    </div>
                  </div>
                <% end %>
              </div>
            <% end %>

            <%= if @cleanup_in_progress do %>
              <div class="flex flex-col items-center gap-2 py-4">
                <span class="loading loading-spinner loading-md"></span>
                <p class="text-sm">
                  Deleting... ({@cleanup_progress.deleted} of {@cleanup_progress.total})
                </p>
                <progress
                  class="progress progress-error w-full"
                  value={@cleanup_progress.deleted}
                  max={@cleanup_progress.total}
                >
                </progress>
              </div>
            <% else %>
              <div class="modal-action">
                <button phx-click="cancel_cleanup" class="btn">Cancel</button>
                <%= if @cleanup_preview && @cleanup_preview.to_delete > 0 do %>
                  <button phx-click="confirm_cleanup" class="btn btn-error">
                    Delete {@cleanup_preview.to_delete} Tags
                  </button>
                <% else %>
                  <p class="text-sm text-base-content/60">No tags to delete</p>
                <% end %>
              </div>
            <% end %>
          </div>
          <div class="modal-backdrop" phx-click="cancel_cleanup"></div>
        </div>
      <% end %>
    </div>
    """
  end

  defp format_date(nil), do: "N/A"

  defp format_date(date_string) do
    case DateTime.from_iso8601(date_string) do
      {:ok, dt, _} -> Calendar.strftime(dt, "%Y-%m-%d %H:%M")
      _ -> date_string
    end
  end

  defp format_bytes(nil), do: "N/A"
  defp format_bytes(bytes) when is_integer(bytes) do
    cond do
      bytes >= 1_073_741_824 -> "#{Float.round(bytes / 1_073_741_824, 2)} GB"
      bytes >= 1_048_576 -> "#{Float.round(bytes / 1_048_576, 2)} MB"
      bytes >= 1024 -> "#{Float.round(bytes / 1024, 2)} KB"
      true -> "#{bytes} B"
    end
  end
  defp format_bytes(_), do: "N/A"

  @impl true
  def handle_event("refresh", _params, socket) do
    socket =
      socket
      |> assign(:loading, true)
      |> assign(:error, nil)

    send(self(), :load_tags)
    {:noreply, socket}
  end

  @impl true
  def handle_event("delete_tag", %{"tag" => tag}, socket) do
    registry_name = socket.assigns.registry_name
    repository_name = socket.assigns.repository_name

    socket =
      case Registry.delete_tag(registry_name, repository_name, tag) do
        {:ok, _} ->
          tags = Enum.reject(socket.assigns.tags, &(&1["tag"] == tag))

          socket
          |> assign(:tags, tags)
          |> put_flash(:info, "Tag '#{tag}' deleted successfully")

        {:error, reason} ->
          socket
          |> put_flash(:error, "Failed to delete tag: #{inspect(reason)}")
      end

    {:noreply, socket}
  end

  @impl true
  def handle_event("show_cleanup_modal", _params, socket) do
    preview = calculate_cleanup_preview(socket.assigns.tags)

    socket =
      socket
      |> assign(:show_cleanup_modal, true)
      |> assign(:cleanup_preview, preview)

    {:noreply, socket}
  end

  @impl true
  def handle_event("cancel_cleanup", _params, socket) do
    socket =
      socket
      |> assign(:show_cleanup_modal, false)
      |> assign(:cleanup_preview, nil)

    {:noreply, socket}
  end

  @impl true
  def handle_event("confirm_cleanup", _params, socket) do
    preview = socket.assigns.cleanup_preview

    socket =
      socket
      |> assign(:cleanup_in_progress, true)
      |> assign(:cleanup_progress, %{deleted: 0, total: preview.to_delete})

    send(self(), {:delete_next_tag, preview.delete_list, 0})

    {:noreply, socket}
  end

  @impl true
  def handle_info({:delete_next_tag, [], deleted_count}, socket) do
    send(self(), :load_tags)

    socket =
      socket
      |> assign(:show_cleanup_modal, false)
      |> assign(:cleanup_preview, nil)
      |> assign(:cleanup_in_progress, false)
      |> assign(:cleanup_progress, nil)
      |> assign(:loading, true)
      |> put_flash(:info, "Successfully deleted #{deleted_count} tags")

    {:noreply, socket}
  end

  @impl true
  def handle_info({:delete_next_tag, [tag_name | rest], deleted_count}, socket) do
    registry_name = socket.assigns.registry_name
    repository_name = socket.assigns.repository_name

    # Find the tag data to get the manifest digest
    tag_data = Enum.find(socket.assigns.tags, &(&1["tag"] == tag_name))

    new_count =
      if tag_data do
        result = Registry.delete_manifest(registry_name, repository_name, tag_data["manifest_digest"])
        IO.inspect(result, label: "Delete result for #{tag_name}")

        case result do
          {:ok, _} -> deleted_count + 1
          {:error, _} -> deleted_count
        end
      else
        IO.puts("Tag data not found for #{tag_name}")
        deleted_count
      end

    socket =
      socket
      |> assign(:cleanup_progress, %{
        deleted: socket.assigns.cleanup_progress.deleted + 1,
        total: socket.assigns.cleanup_progress.total
      })

    send(self(), {:delete_next_tag, rest, new_count})

    {:noreply, socket}
  end

  defp calculate_cleanup_preview(tags) do
    min_keep = 8
    max_age_days = 7
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

    %{
      total: length(tags),
      to_keep: min(length(tags), min_keep) + length(candidates) - length(to_delete),
      to_delete: length(to_delete),
      delete_list: Enum.map(to_delete, & &1["tag"])
    }
  end
end
