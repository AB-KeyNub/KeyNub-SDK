function outFile = build(libDir, varargin)
%KEYNUB.BUILD Compiles the MEX gateway for this platform and MATLAB release.
%
%   keynub.build() compiles licd_mex from src/licd_mex.c against the prebuilt
%   static library the repository carries for this platform under
%   natives/<platform>/ (see NATIVES.md), and adds the result,
%   bindings/matlab/mex/licd_mex.<mexext>, to the MATLAB path. It needs a C
%   compiler that MATLAB knows about (mex -setup C).
%
%   keynub.build(LIBDIR) takes the library from LIBDIR instead.
%
%   The gateway is linked statically, so it is one self-contained file. A MEX
%   file that depended on keynub_licdongle.dll would need that DLL on the system
%   PATH, because Windows resolves a MEX file's dependencies against the MATLAB
%   executable's directory and not the MEX file's own.
%
%   Options:
%     'Verbose' (false)  pass -v to mex
%
%   See also keynub.Context, mex.

narginchk(0, 3);
opts = struct('Verbose', false);
for i = 1:2:numel(varargin)
    name = varargin{i};
    if ~isfield(opts, name)
        error('KeyNub:licdongle:invalidArgument', 'unknown option ''%s''', name);
    end
    opts.(name) = varargin{i + 1};
end

matlabDir = fileparts(fileparts(mfilename('fullpath'))); % .../bindings/matlab
repoDir = fileparts(fileparts(matlabDir));               % the repository root
if nargin < 1 || isempty(libDir)
    libDir = fullfile(repoDir, 'natives', platformDir());
end
if exist(libDir, 'dir') ~= 7
    error('KeyNub:licdongle:libraryDirMissing', ...
        ['''%s'' is not a directory. Point keynub.build at the natives/<platform> ' ...
         'folder holding keynub_licdongle_static (see NATIVES.md).'], libDir);
end

if ispc
    lib = fullfile(libDir, 'keynub_licdongle_static.lib');
    % The static library carries Mbed TLS and hidapi; these are what it still
    % needs from the system.
    linkLibs = 'LINKLIBS=$LINKLIBS setupapi.lib hid.lib advapi32.lib bcrypt.lib';
elseif ismac
    lib = fullfile(libDir, 'libkeynub_licdongle_static.a');
    linkLibs = 'LINKLIBS=$LINKLIBS -framework IOKit -framework CoreFoundation';
else
    lib = fullfile(libDir, 'libkeynub_licdongle_static.a');
    linkLibs = 'LINKLIBS=$LINKLIBS -ludev -lpthread';
end
if exist(lib, 'file') ~= 2
    error('KeyNub:licdongle:libraryMissing', ...
        'could not find %s (see NATIVES.md for the prebuilt library)', lib);
end

outDir = fullfile(matlabDir, 'mex');
if exist(outDir, 'dir') ~= 7
    mkdir(outDir);
end

args = {'-outdir', outDir, ['-I' fullfile(repoDir, 'include')], ...
        fullfile(matlabDir, 'src', 'licd_mex.c'), lib, linkLibs};
if opts.Verbose
    args = [{'-v'}, args];
end
mex(args{:});

outFile = fullfile(outDir, ['licd_mex.' mexext]);
addpath(outDir);
fprintf('Built %s\n', outFile);
end

function d = platformDir()
%PLATFORMDIR The natives/<platform> folder for this MATLAB.
arch = computer('arch');
switch arch
    case 'win64',   d = 'win-x64';
    case 'win32',   d = 'win-x86';
    case 'glnxa64', d = 'linux-x64';
    case 'maci64',  d = 'osx-x64';
    case 'maca64',  d = 'osx-arm64';
    otherwise
        error('KeyNub:licdongle:unsupportedPlatform', ...
            'no prebuilt library for MATLAB architecture ''%s'' (see NATIVES.md)', arch);
end
end
