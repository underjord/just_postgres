defmodule JustPostgresTest do
  use ExUnit.Case
  doctest JustPostgres

  test "greets the world" do
    assert JustPostgres.hello() == :world
  end
end
