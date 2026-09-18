defmodule KeyNub.LicDongle.MixProject do
  use Mix.Project

  @version "1.1.1"
  @source "https://github.com/AB-KeyNub/KeyNub-SDK"
  @website "https://www.keynub.com/developers/elixir/"

  def project do
    [
      app: :keynub_licdongle,
      version: @version,
      elixir: "~> 1.13",
      compilers: [:elixir_make] ++ Mix.compilers(),
      make_targets: ["all"],
      make_clean: ["clean"],
      start_permanent: false,
      deps: deps(),
      description: description(),
      package: package(),
      name: "KeyNub.LicDongle",
      source_url: @source,
      homepage_url: @website,
      docs: docs()
    ]
  end

  def application do
    [extra_applications: []]
  end

  defp deps do
    [
      {:elixir_make, "~> 0.8", runtime: false},
      {:ex_doc, "~> 0.34", only: :dev, runtime: false}
    ]
  end

  defp description do
    "Client for the KeyNub USB license dongle: genuineness check, license records, " <>
      "hardware counters and dongle-bound encryption. A small NIF loads the SDK's native " <>
      "library at run time; nothing is linked."
  end

  defp package do
    [
      name: "keynub_licdongle",
      files: ~w(lib c_src Makefile Makefile.win mix.exs README.md CHANGELOG.md LICENSE .formatter.exs),
      licenses: ["Apache-2.0"],
      links: %{
        "Website" => @website,
        "GitHub" => @source,
        "Native library" => "#{@source}/blob/master/NATIVES.md"
      }
    ]
  end

  defp docs do
    [
      main: "readme",
      extras: ["README.md", "CHANGELOG.md"],
      source_url_pattern: "#{@source}/blob/master/bindings/elixir/%{path}#L%{line}"
    ]
  end
end
