defmodule SymphonyElixir.PublicUrlTest do
  use ExUnit.Case, async: true

  alias SymphonyElixir.Config.Schema
  alias SymphonyElixir.HttpServer

  defp server(attrs), do: Schema.Server.changeset(%Schema.Server{}, attrs)

  test "public_url sets the endpoint URL and allows exactly that origin" do
    assert {url, ["https://symphony.example.com"]} =
             HttpServer.endpoint_origin(%{public_url: "https://symphony.example.com"}, "0.0.0.0", :iap)

    assert url == [scheme: "https", host: "symphony.example.com", port: 443]

    assert {_url, ["http://10.0.0.5:8080"]} =
             HttpServer.endpoint_origin(%{public_url: "http://10.0.0.5:8080/"}, "0.0.0.0", :iap)
  end

  test "without public_url, sign-in keeps the page's own host and local mode keeps localhost" do
    assert {[host: "0.0.0.0"], :conn} = HttpServer.endpoint_origin(%{public_url: nil}, "0.0.0.0", :iap)
    assert {[host: "127.0.0.1"], origins} = HttpServer.endpoint_origin(%{public_url: nil}, nil, :local)
    assert is_list(origins) and origins != []
  end

  test "public_url must be an http(s) origin" do
    assert server(%{"public_url" => "https://symphony.example.com"}).valid?
    assert server(%{"public_url" => "https://symphony.example.com/"}).valid?
    refute server(%{"public_url" => "symphony.example.com"}).valid?
    refute server(%{"public_url" => "ftp://symphony.example.com"}).valid?
    refute server(%{"public_url" => "https://symphony.example.com/dashboard"}).valid?
  end
end
