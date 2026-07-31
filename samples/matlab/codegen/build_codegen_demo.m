function build_codegen_demo(sdkBuildDir)
%BUILD_CODEGEN_DEMO Generates a dongle-gated MEX/library from keynub_unlock_codegen.
%
%   build_codegen_demo(SDKBUILDDIR) runs MATLAB Coder over
%   keynub_unlock_codegen, linking the SDK's static library from SDKBUILDDIR (the
%   directory the SDK's CMake project was built into).
%
%   The point of the exercise is the configuration, not the output: the same
%   CustomSource / CustomInclude / CustomLibrary settings are what you add to a
%   Simulink Coder model configuration (Code Generation > Custom Code) to carry a
%   licence check into generated code. Doing it here in a script rather than with
%   coder.updateBuildInfo inside the entry function keeps the paths out of the
%   generated code, where they would have to be compile-time constants.
%
%   Requires MATLAB Coder.

narginchk(1, 1);
if isempty(ver('matlabcoder'))
    error('KeyNub:licdongle:noCoder', ...
        'MATLAB Coder is required to run this sample');
end

here = fileparts(mfilename('fullpath'));
sdkDir = fileparts(fileparts(fileparts(here))); % .../SDK

cfg = coder.config('mex');
cfg.CustomSource = fullfile(here, 'keynub_gate.c');
cfg.CustomInclude = sprintf('"%s" "%s"', here, fullfile(sdkDir, 'core', 'include'));
cfg.CustomLibrary = strjoin(staticLibraries(sdkBuildDir), ' ');

% Example inputs: a 4 KB blob in, up to 4 KB of plaintext out.
exampleBlob = zeros(4096, 1, 'uint8');
codegen('-config', cfg, fullfile(here, 'keynub_unlock_codegen.m'), ...
    '-args', {exampleBlob, coder.Constant(4096)}, '-report');

fprintf(['Generated keynub_unlock_codegen_mex. The report shows the licence check\n' ...
         'compiled into the C code — there is no MATLAB dependency left in it.\n']);
end

function libs = staticLibraries(buildDir)
%STATICLIBRARIES The SDK static libraries plus this platform's system libraries.
if ispc
    patterns = {'*keynub_licdongle_static*.lib', '*mbedx509*.lib', '*mbedcrypto*.lib', ...
                '*hidapi*.lib'};
    system = {'setupapi.lib', 'hid.lib', 'advapi32.lib', 'bcrypt.lib'};
elseif ismac
    patterns = {'libkeynub_licdongle_static.a', 'libmbedx509.a', 'libmbedcrypto.a', ...
                'libhidapi*.a'};
    system = {'-framework IOKit', '-framework CoreFoundation'};
else
    patterns = {'libkeynub_licdongle_static.a', 'libmbedx509.a', 'libmbedcrypto.a', ...
                'libhidapi*.a'};
    system = {'-ludev', '-lpthread'};
end

libs = cell(1, numel(patterns));
for i = 1:numel(patterns)
    hits = dir(fullfile(buildDir, '**', patterns{i}));
    hits = hits(~[hits.isdir]);
    if isempty(hits)
        error('KeyNub:licdongle:libraryMissing', ...
            'could not find %s under ''%s''; build the SDK first', patterns{i}, buildDir);
    end
    libs{i} = ['"' fullfile(hits(1).folder, hits(1).name) '"'];
end
libs = [libs, system];
end
