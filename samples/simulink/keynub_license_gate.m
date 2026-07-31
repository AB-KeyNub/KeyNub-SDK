function modelName = keynub_license_gate()
%KEYNUB_LICENSE_GATE Builds a Simulink model that is gated on a KeyNub dongle.
%
%   Creates the model in code rather than shipping a .slx, for two reasons: a
%   .slx is a binary tied to the MATLAB release that saved it (and would not open
%   in an older one), and a script shows exactly which blocks and parameters
%   matter — which is the part worth copying into your own model.
%
%   Requires the binding folder on the path:
%       addpath('<SDK>/bindings/matlab');
%       keynub_license_gate
%
%   What it builds:
%
%       [ keynub.LicenseCheck ] --> [ Display ]
%        MATLAB System block          licensed
%
%   The block verifies a genuine dongle when the model initialises and again
%   every 100 steps, so unplugging the dongle mid-run stops the simulation.
%
%   For a real product do not stop at a boolean: route a signal the model needs
%   through keynub.Session/appDecrypt (see
%   samples/matlab/licence_protected_parameters.m). A gate that only produces
%   true or false is removed by deleting one block.

modelName = 'keynub_license_gate_demo';

if bdIsLoaded(modelName)
    close_system(modelName, 0);
end
new_system(modelName);

gate = [modelName '/License Check'];
add_block('simulink/User-Defined Functions/MATLAB System', gate, ...
    'System', 'keynub.LicenseCheck', 'Position', [140 100 320 160]);

% The System object's public properties appear as block parameters.
set_param(gate, 'Serial', '');              % '' = first dongle found
set_param(gate, 'RecheckEverySteps', '100'); % notice a dongle being unplugged
set_param(gate, 'StopOnFailure', 'on');      % stop the simulation if unlicensed

display = [modelName '/licensed'];
add_block('simulink/Sinks/Display', display, 'Position', [400 110 460 150]);
add_line(modelName, 'License Check/1', 'licensed/1');

set_param(modelName, 'StopTime', '1', 'SolverType', 'Fixed-step', 'FixedStep', '0.001');
open_system(modelName);

fprintf(['Built model ''%s''. Run it with a dongle attached.\n' ...
         'With no dongle it stops immediately with KeyNub:licdongle:notLicensed,\n' ...
         'which is the intended behaviour of StopOnFailure.\n'], modelName);
end
