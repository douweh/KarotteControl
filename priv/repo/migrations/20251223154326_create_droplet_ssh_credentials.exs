defmodule KarotteControl.Repo.Migrations.CreateDropletSshCredentials do
  use Ecto.Migration

  def change do
    create table(:droplet_ssh_credentials) do
      add :droplet_id, :string, null: false
      add :droplet_name, :string
      add :ssh_user, :string, default: "root"
      add :ssh_private_key, :binary, null: false
      add :ssh_port, :integer, default: 22

      timestamps(type: :utc_datetime)
    end

    create unique_index(:droplet_ssh_credentials, [:droplet_id])
  end
end
