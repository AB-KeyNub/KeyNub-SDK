import os

from conan import ConanFile
from conan.errors import ConanInvalidConfiguration
from conan.tools.files import copy, get

required_conan_version = ">=2.0"


class KeynubLicdongleConan(ConanFile):
    name = "keynub_licdongle"
    description = ("KeyNub USB-C license dongle SDK: the C API, the header-only C++11 wrapper "
                   "and the flat companion API over the prebuilt keynub_licdongle library.")
    license = ("Apache-2.0", "LicenseRef-KeyNub-Binary")
    url = "https://github.com/AB-KeyNub/KeyNub-SDK"
    homepage = "https://www.keynub.com/developers/c-cpp/"
    topics = ("license-dongle", "software-licensing", "copy-protection", "usb-dongle")
    package_type = "shared-library"
    settings = "os", "arch", "compiler", "build_type"

    _os_names = {"Windows": "win", "Linux": "linux", "Macos": "osx"}
    _arch_names = {"x86_64": "x64", "x86": "x86", "armv8": "arm64"}

    def _natives(self):
        os_name = self._os_names.get(str(self.settings.os))
        arch_name = self._arch_names.get(str(self.settings.arch))
        if os_name is None or arch_name is None:
            raise ConanInvalidConfiguration(
                "no prebuilt keynub_licdongle library for %s %s" % (self.settings.os, self.settings.arch))
        return os_name + "-" + arch_name

    def validate(self):
        self._natives()

    def package_id(self):
        # One prebuilt set serves every compiler and build type.
        del self.info.settings.compiler
        del self.info.settings.build_type

    def source(self):
        get(self, **self.conan_data["sources"][self.version], strip_root=True)

    def package(self):
        src = self.source_folder
        inc = os.path.join(self.package_folder, "include")
        copy(self, "licdongle.h", os.path.join(src, "include"), inc)
        copy(self, "licdongle.hpp", os.path.join(src, "bindings", "cpp"), inc)
        copy(self, "licd_flat.h", os.path.join(src, "bindings", "flat"), inc)
        copy(self, "licd_labview.h", os.path.join(src, "bindings", "labview"), inc)
        natives = os.path.join(src, "natives", self._natives())
        if self.settings.os == "Windows":
            copy(self, "keynub_licdongle*.dll", natives, os.path.join(self.package_folder, "bin"))
            copy(self, "keynub_licdongle.lib", natives, os.path.join(self.package_folder, "lib"))
            copy(self, "keynub_licdongle_flat.lib", natives, os.path.join(self.package_folder, "lib"))
        else:
            copy(self, "libkeynub_licdongle.*", natives, os.path.join(self.package_folder, "lib"))
            copy(self, "libkeynub_licdongle_flat.*", natives, os.path.join(self.package_folder, "lib"))
        for name in ("LICENSE", "BINARY-LICENSE.txt", "NOTICE", "THIRD-PARTY-NOTICES.txt"):
            copy(self, name, src, os.path.join(self.package_folder, "licenses"))

    def package_info(self):
        self.cpp_info.set_property("cmake_file_name", "keynub_licdongle")
        self.cpp_info.set_property("cmake_target_name", "keynub::keynub")
        core = self.cpp_info.components["licdongle"]
        core.set_property("cmake_target_name", "keynub::licdongle")
        core.libs = ["keynub_licdongle"]
        cpp = self.cpp_info.components["licdongle_cpp"]
        cpp.set_property("cmake_target_name", "keynub::licdongle_cpp")
        cpp.requires = ["licdongle"]
        flat = self.cpp_info.components["licdongle_flat"]
        flat.set_property("cmake_target_name", "keynub::licdongle_flat")
        flat.libs = ["keynub_licdongle_flat"]
