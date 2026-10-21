defmodule SymphonyElixir.Repo.Migrations.CreateStateDocuments do
  @moduledoc false
  use Ecto.Migration

  @spec change() :: term()
  def change do
    create table(:state_documents, primary_key: false) do
      add(:key, :text, primary_key: true)
      add(:body, :binary, null: false)
      add(:updated_at, :utc_datetime_usec, null: false, default: fragment("now()"))
    end
  end
end
