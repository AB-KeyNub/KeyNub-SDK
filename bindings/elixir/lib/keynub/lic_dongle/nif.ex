defmodule KeyNub.LicDongle.Nif do
  @moduledoc false
  # The NIF (c_src/keynub_licdongle_nif.c): every function of the flat API,
  # with the flat API's own shape. KeyNub.LicDongle turns the results into
  # values and errors.

  @on_load :load_nif

  def load_nif do
    priv = :code.priv_dir(:keynub_licdongle) |> to_string()
    :erlang.load_nif(String.to_charlist(Path.join(priv, "keynub_licdongle_nif")), 0)
  end

  def load(_path), do: nif_error()
  def loaded_path, do: nif_error()
  def version, do: nif_error()
  def device_count, do: nif_error()
  def device_serial(_index), do: nif_error()
  def device_path(_index), do: nif_error()
  def strerror(_code), do: nif_error()
  def last_error(_handle), do: nif_error()
  def open(_serial), do: nif_error()
  def open_path(_path), do: nif_error()
  def close(_handle), do: nif_error()
  def set_trust_root(_handle, _der), do: nif_error()
  def get_serial(_handle), do: nif_error()
  def get_info(_handle), do: nif_error()
  def verify_genuine(_handle), do: nif_error()
  def session_open(_handle), do: nif_error()
  def session_close(_handle), do: nif_error()
  def write_auth(_handle, _der), do: nif_error()
  def write_auth_rotate(_handle, _der), do: nif_error()
  def record_count(_handle), do: nif_error()
  def record_name(_handle, _index), do: nif_error()
  def record_size(_handle, _name), do: nif_error()
  def record_read(_handle, _name, _capacity), do: nif_error()
  def record_write(_handle, _name, _data), do: nif_error()
  def record_erase(_handle, _name), do: nif_error()
  def record_erase_all(_handle), do: nif_error()
  def counter_read(_handle, _id), do: nif_error()
  def counter_increment(_handle, _id), do: nif_error()
  def app_encrypt(_handle, _scope, _plaintext, _capacity), do: nif_error()
  def app_decrypt(_handle, _packed, _capacity), do: nif_error()

  defp nif_error, do: :erlang.nif_error(:nif_not_loaded)
end
