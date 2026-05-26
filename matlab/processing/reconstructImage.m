function img = reconstructImage(RcvData, Trans, PData, Resource, varargin)
% reconstructImage  Delay-and-sum reconstruction for plane-wave RF data.
%
%   img = reconstructImage(RcvData, Trans, PData, Resource)
%   img = reconstructImage(RcvData, Trans, PData, Resource, 'angles', anglesRad)
%
%   Performs coherent plane-wave compounding over all steering angles.
%   Returns a 2-D intensity image (double, linear scale).
%
%   Inputs
%   ------
%   RcvData   : cell array {bufnum} of int16 RF matrices (rows x cols x frames)
%   Trans     : Verasonics Trans structure
%   PData     : Verasonics PData structure
%   Resource  : Verasonics Resource structure
%
%   Optional name-value pairs
%   -------------------------
%   'angles'  : steering angles in radians (default: 0)
%   'bufnum'  : which RcvData buffer to use (default: 2)
%   'framenum': which frame to reconstruct (default: 1)
%
%   Output
%   ------
%   img       : [PData.Size(1) x PData.Size(2)] double intensity image

p = inputParser();
addParameter(p, 'angles',   0,   @isnumeric);
addParameter(p, 'bufnum',   2,   @isnumeric);
addParameter(p, 'framenum', 1,   @isnumeric);
parse(p, varargin{:});

angles   = p.Results.angles;
bufnum   = p.Results.bufnum;
framenum = p.Results.framenum;

c        = Resource.Parameters.speedOfSound;  % m/s
fs       = Trans.frequency * 1e6;             % sampling frequency Hz
lambda   = (c / 1000) / Trans.frequency;      % wavelength mm

%% Extract RF frame
rf_all = RcvData{bufnum};  % rows x cols x frames
if ndims(rf_all) == 3
    rf = double(rf_all(:, :, framenum));
else
    rf = double(rf_all);
end
[nSamples, nCh] = size(rf);

%% Build pixel grid from PData
nz   = PData.Size(1);
nx   = PData.Size(2);
x_px = PData.Origin(1) + (0:nx-1) * PData.PDelta(1);   % mm
z_px = PData.Origin(3) + (0:nz-1) * PData.PDelta(3);   % mm
[X, Z] = meshgrid(x_px, z_px);

%% Element positions
xElem = Trans.ElementPos(:, 1);  % mm

%% Delay-and-sum over angles
iqSum = zeros(nz, nx);

for iAngle = 1:length(angles)
    theta  = angles(iAngle);
    sinTh  = sin(theta);
    cosTh  = cos(theta);

    % Analytic signal (Hilbert) of each channel
    rfHilbert = hilbert(rf);

    for iCh = 1:nCh
        xe = xElem(iCh);

        % Transmit delay: plane wave
        t_tx = (X * sinTh + Z * cosTh) / (c / 1000);   % ms

        % Receive delay: element to pixel
        r_rx = sqrt((X - xe).^2 + Z.^2);                % mm
        t_rx = r_rx / (c / 1000);                        % ms

        % Total sample index
        t_total_s  = (t_tx + t_rx) * 1e-3;              % s
        sampleIdx  = t_total_s * fs + PData.startSample;

        % Clamp to valid range
        sampleIdx(sampleIdx < 1)       = 1;
        sampleIdx(sampleIdx > nSamples) = nSamples;

        % Interpolate
        iqInterp = interp1(1:nSamples, rfHilbert(:, iCh), sampleIdx(:), 'linear', 0);
        iqSum    = iqSum + reshape(iqInterp, nz, nx);
    end
end

img = abs(iqSum);
end
