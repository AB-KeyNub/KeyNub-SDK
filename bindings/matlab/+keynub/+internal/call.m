function varargout = call(varargin)
%KEYNUB.INTERNAL.CALL Calls the licd_mex gateway. Internal to the binding.
%
%   Not part of the supported API — use keynub.Context, keynub.Dongle and
%   keynub.Session. This exists to give one clear error when the MEX gateway has
%   not been built, instead of MATLAB's bare "Undefined function 'licd_mex'".
%
%   See also keynub.build.

persistent ready
if isempty(ready)
    if exist('licd_mex', 'file') ~= 3 % 3 = MEX-file
        here = fileparts(mfilename('fullpath'));          % .../+keynub/+internal
        mexDir = fullfile(here, '..', '..', 'mex');
        if exist(fullfile(mexDir, ['licd_mex.' mexext]), 'file') == 3
            addpath(mexDir); % the usual case: built, just not on the path yet
        else
            error('KeyNub:licdongle:mexMissing', ...
                ['The KeyNub MEX gateway (licd_mex.%s) was not found.\n' ...
                 'Build it once with:\n' ...
                 '    keynub.build(''<directory holding the prebuilt native>'')\n' ...
                 'or copy a prebuilt gateway for this platform into:\n    %s'], ...
                mexext, mexDir);
        end
    end
    ready = true;
end

if nargout > 0
    [varargout{1:nargout}] = licd_mex(varargin{:});
else
    licd_mex(varargin{:});
end
end
