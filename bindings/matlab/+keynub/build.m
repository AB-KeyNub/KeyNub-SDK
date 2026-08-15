function outFile = build(buildDir, varargin)
%KEYNUB.BUILD Compiles the MEX gateway for this platform and MATLAB release.
%
%   keynub.build(BUILDDIR) compiles licd_mex from the SDK sources, linking the
%   static libraries in BUILDDIR — the directory holding the prebuilt native
%   project into, e.g.
%
%       see NATIVES.md for the prebuilt library
%       see NATIVES.md for the prebuilt library
%       >> keynub.build('../../build')      % from bindings/matlab
%
%   The result goes to bindings/matlab/mex/licd_mex.<mexext> and is added to
%   the MATLAB path. A release ships this prebuilt, so customers do not need a
%   compiler; you only need this when building the SDK from source.
%
%   Static linking is deliberate: it makes the gateway one self-contained file.
%   A MEX file that depended on keynub_licdongle.dll would need that DLL on the
%   system PATH, because Windows resolves a MEX file's dependencies against the
%   MATLAB executable's directory and not the MEX file's own.
%
%   Options:
%     'Verbose' (false)  pass -v to mex
%
%   See also keynub.Context, mex.

narginchk(1, 3);
opts = struct('Verbose', false);
for i = 1:2:numel(varargin)
    name = varargin{i};
    if ~isfield(opts, name)
        error('KeyNub:licdongle:invalidArgument', 'unknown option ''%s''', name);
    end
    opts.(name) = varargin{i + 1};
end

matlabDir = fileparts(fileparts(mfilename('fullpath'))); % .../bindings/matlab
sdkDir = fileparts(fileparts(matlabDir));                % .../SDK
if exist(buildDir, 'dir') ~= 7
    error('KeyNub:licdongle:buildDirMissing', ...
        ['''%s'' is not a directory. Point keynub.build at the prebuilt native ' ...
         'build directory (configure and build it first).'], buildDir);
end

% --- sources ---------------------------------------------------------------
sources = {fullfile(matlabDir, 'src', 'licd_mex.c')};
includes = {['-I' fullfile(sdkDir, 'core', 'include')]};
defines = {};

% --- static libraries, in link order --------------------------------------
if ispc
    patterns = {'*keynub_licdongle_static*.lib', '*mbedx509*.lib', '*mbedcrypto*.lib', ...
                '*hidapi*.lib'};
else
    patterns = {'libkeynub_licdongle_static.a', 'libmbedx509.a', 'libmbedcrypto.a', ...
                'libhidapi*.a'};
end
libs = cell(1, numel(patterns));
for i = 1:numel(patterns)
    libs{i} = findLibrary(buildDir, patterns{i});
end

% --- platform link libraries ----------------------------------------------
% hidapi's backend and Mbed TLS's entropy source, which the prebuilt native already includes as
% usage requirements but mex knows nothing about.
if ispc
    linkLibs = 'LINKLIBS=$LINKLIBS setupapi.lib hid.lib advapi32.lib bcrypt.lib';
elseif ismac
    linkLibs = 'LINKLIBS=$LINKLIBS -framework IOKit -framework CoreFoundation';
else
    linkLibs = 'LINKLIBS=$LINKLIBS -ludev -lpthread';
end

outDir = fullfile(matlabDir, 'mex');
if exist(outDir, 'dir') ~= 7
    mkdir(outDir);
end

args = [{'-outdir', outDir}, includes, defines, sources, libs, {linkLibs}];
if opts.Verbose
    args = [{'-v'}, args];
end
mex(args{:});

outFile = fullfile(outDir, ['licd_mex.' mexext]);
addpath(outDir);
fprintf('Built %s\n', outFile);
end

function path = findLibrary(buildDir, pattern)
%FINDLIBRARY Locates one static library in the native directory.
%   Searched rather than hard-coded, because the layout differs between
%   single-config generators (Ninja, Makefiles) and multi-config ones (Visual
%   Studio, Xcode), which add a Release/ or Debug/ level.
hits = dir(fullfile(buildDir, '**', pattern));
hits = hits(~[hits.isdir]);
if isempty(hits)
    error('KeyNub:licdongle:libraryMissing', ...
        ['could not find %s under ''%s''.\nBuild the SDK first:\n' ...
         '    see NATIVES.md for the prebuilt library
end
if numel(hits) > 1
    % Several configurations built: prefer Release, else say which one was used
    % rather than picking silently.
    isRelease = contains({hits.folder}, 'Release');
    if any(isRelease)
        hits = hits(isRelease);
    end
    if numel(hits) > 1
        warning('KeyNub:licdongle:ambiguousLibrary', ...
            'found %d copies of %s; using %s', numel(hits), pattern, hits(1).folder);
    end
end
path = fullfile(hits(1).folder, hits(1).name);
end
