% File name: SetUpL38_22vFlashAngles.m - Example of 2-1 synthetic aperture 
% Description:
%   Sequence programming file for L38-22v Linear array, using 2-1
%   synthetic aperture plane wave transmits and receive acquisitions on
%   128 channels system. 128 transmit channels and 85 or 86 receive channels
%   are active and positioned as follows (each char represents 4 elements)
%   for each of the 3 synthetic apertures.
%
%   Element Nos.                                1         1    1               2
%                               6    8          2         7    9               5
%               1               5    6          9         2    3               6
%   Aperture 1: |               |    |          |         |    |               |
%               tttttttttttttttttttttttttttttttt--------------------------------
%               rrrrrrrrrrrrrrrrrrrrr-------------------------------------------
%               |               |    |          |         |    |               |
%   Aperture 2: |               |    |          |         |    |               |
%               ----------------tttttttttttttttttttttttttttttttt----------------
%               ---------------------rrrrrrrrrrrrrrrrrrrrrr---------------------
%               |               |    |          |         |    |               |
%   Aperture 3: |               |    |          |         |    |               |
%               --------------------------------tttttttttttttttttttttttttttttttt
%               -------------------------------------------rrrrrrrrrrrrrrrrrrrrr
%               |               |    |          |         |    |               |
%
%   The receive data from each of these apertures are stored under
%   different acqNums in the Receive buffer. The reconstruction sums the
%   IQ data from the 3 aquisitions and computes intensity values to produce
%   the full frame. Processing is asynchronous with respect to acquisition.
%
% Notice:
%   This file is provided by Verasonics to end users as a programming
%   example for the Verasonics Vantage NXT Research Ultrasound System.
%   Verasonics makes no claims as to the functionality or intended
%   application of this program and the user assumes all responsibility
%   for its use.
% % dbz 2025/05/06
% no cdw. just first aperture 0 angle planewave.
% Copyright © 2013-2023 Verasonics, Inc.

% Preserve variables set by ScanControlPanel before this script runs
% (sweepLateralY_mm is used by saveRF_dbz_txt.m to tag the RF filename).
clearvars -except sweepLateralY_mm guiLog stage

%% CONNECT MOTION STAGE
addpath('C:\Users\Administrator\Desktop\3d_motion_stage\FMC4030-Matlab-demo\Matlab\')
addpath(fullfile(fileparts(mfilename('fullpath')), '..', 'motion'))
setupLog('Script started — paths added');

% Reload library — suppress all warnings during load (name + preprocessor warnings)
if libisloaded('FMC40300x2DDll')
    unloadlibrary('FMC40300x2DDll')
end
if ~libisloaded('FMC40300x2DDll')
    warnState = warning('off', 'all');
    loadlibrary('FMC4030-Dll.dll', 'FMC4030-DLL.h')
    warning(warnState);   % restore previous warning state
end
setupLog('DLL loaded');

stage = StageController();
stage.connect();
setupLog('Stage connected');

posPtr = libpointer('singlePtr', 0);

%%
P.startDepth = 5;   % Acquisition depth in wavelengths
P.endDepth = 128;   % This should preferrably be a multiple of 128 samples.

%m = 128;
nw = 1;% % specify the cdw code length, now there is only 4 8 16
na = 1;      % Set na = number of angles.
if (na > 1)
    dtheta = (12*pi/180)/(na-1);
    startAngle = -12*pi/180/2;
else
    dtheta = 0;
    startAngle=0;
end % set dtheta to range over +/- 6 degrees.

% Define system parameters.
Resource.Parameters.numTransmit = 128;  % number of transmit channels.
Resource.Parameters.numRcvChannels = 128;  % number of receive channels.
Resource.Parameters.speedOfSound = 1540;    % set speed of sound in m/sec before calling computeTrans
Resource.Parameters.verbose = 2;
Resource.Parameters.initializeOnly = 0;
Resource.Parameters.simulateMode = 0;
Resource.Parameters.Connector = 2;

Resource.VDAS.watchdogTimeout = 80000;
% Specify Trans structure array.
Trans.name = 'L38-22v';
Trans.units = 'wavelengths'; % Explicit declaration avoids warning message when selected by default
%Trans.units = 'mm';
Trans = computeTrans(Trans);  % L38-22v transducer is a 'known' transducer so we can use computeTrans.
Trans.maxHighVoltage = 20;  % set maximum high voltage limit for pulser supply.

% VSX GUI Voltage Setting
TPC(1).hv             = 4.0;
TPC(1).maxHighVoltage = 8.0;   % ← safety ceiling

% Specify PData structure array. reconstruct area
PData.PDelta = [Trans.spacing, 0, 0.5];
PData.Size(1) = ceil((P.endDepth-P.startDepth)/PData.PDelta(3)); % startDepth, endDepth and pdelta set PData.Size.
PData.Size(2) = ceil((Trans.numelements/2*Trans.spacing)/PData.PDelta(1));
PData.Size(3) = 1;      % single image page
PData.Origin = [-Trans.spacing*(Trans.numelements/2-1),0,P.startDepth]; % x,y,z of upper lft crnr.

% PData.PDelta = [Trans.spacing, 0, 0.5];
% PData.Size(1) = ceil((P.endDepth-P.startDepth)/PData.PDelta(3)); % startDepth, endDepth and pdelta set PData.Size.
% PData.Size(2) = ceil((Trans.numelements/2*Trans.spacing)/PData.PDelta(1));
% PData.Size(3) = 1;      % single image page
% PData.Origin = [-Trans.spacing*(Trans.numelements-1)/4,0,P.startDepth]; % x,y,z of upper lft crnr.
% No PData.Region specified, so a default Region for the entire PData array will be created by computeRegions.

% Compute Papod and Paper to calculate apertures for TX and Receive
% structures
% Papod = [ ones(1,128) zeros(1,128); ...
%          zeros(1,64)  ones(1,128) zeros(1,64); ...
%          zeros(1,128)  ones(1,128)];
% Papod = [ ones(1,128) zeros(1,128); ...
%          zeros(1,128)  ones(1,128)];
%Papod = [zeros(1,64)  ones(1,128) zeros(1,64);];
Papod = [ones(1,128) zeros(1,128);];
% Papod = [ ones(1,86) zeros(1,170); ...
%          zeros(1,128)  ones(1,128)];
% create aperture index for each Papod; Paper(i) will be the aperture index
% value for Papod(i)
for i = 1:size(Papod, 1)
    Paper(i) = computeMuxAperture(Papod(i, :), Trans);
end

% Specify Media object. 'pt1.m' script defines array of point targets.
pt1;
Media.MP(:,1) = Media.MP(:,1)-70;
Media.attenuation = -0.5;
%Media.function = 'movePoints';

% ele_dis = 0.1:0.1:54;
% lat_dis = 0:6.9:54;
d_ele        = 0.05;   % sweep step size mm
sweep_length = 60;     % ← change this to set sweep length in mm

% Sweep Length Check
assert(sweep_length > 2 && sweep_length < 80, ...
    'sweep_length = %.1f mm is out of range. Must be between 2 and 80 mm.', sweep_length);

ele_dis = 0:d_ele:sweep_length-d_ele;

lat_dis = 0;
%0:d_lat:14;

%0:-0.1:-79.9;
%-25:0.1:24.9;
%-2.9:0.1:3;
%-25:0.1:24.9;
%-28:0.1:27.9;% set to be even
loc_num = length(ele_dis);
%*length(lat_dis);
% Specify Resources.
Resource.RcvBuffer(1).datatype = 'int16';
Resource.RcvBuffer(1).rowsPerFrame = 4096*na; % this size allows for 2 acqs for each angle, maximum range
Resource.RcvBuffer(1).colsPerFrame = Resource.Parameters.numRcvChannels;
Resource.RcvBuffer(1).numFrames = 10;        % 40 frames used for RF cineloop.

Resource.RcvBuffer(2).datatype = 'int16'; % save the move batch rf data
Resource.RcvBuffer(2).rowsPerFrame = 3*4096*na; % this size allows for maximum range
Resource.RcvBuffer(2).colsPerFrame = Resource.Parameters.numRcvChannels;
Resource.RcvBuffer(2).numFrames = loc_num;
%loc_num;    % 30 frames stored in RcvBuffer.


Resource.InterBuffer(1).datatype = 'complex';
Resource.InterBuffer(1).numFrames = 1;  % one intermediate buffer needed.
Resource.InterBuffer(2).numFrames = 1;

Resource.ImageBuffer(1).datatype = 'double';
Resource.ImageBuffer(1).numFrames = 10;
Resource.ImageBuffer(2).numFrames = 1;
%loc_num;

Resource.DisplayWindow(1).Title = 'L38-22vSynthApe';
Resource.DisplayWindow(1).pdelta = 0.35;
ScrnSize = get(0,'ScreenSize');
DwWidth = ceil(PData(1).Size(2)*PData(1).PDelta(1)/Resource.DisplayWindow(1).pdelta);
DwHeight = ceil(PData(1).Size(1)*PData(1).PDelta(3)/Resource.DisplayWindow(1).pdelta);
Resource.DisplayWindow(1).Position = [250,(ScrnSize(4)-(DwHeight+150))/2, ...  % lower left corner position
                                      DwWidth, DwHeight];
Resource.DisplayWindow(1).ReferencePt = [PData(1).Origin(1),0,PData(1).Origin(3)];   % 2D imaging is in the X,Z plane
Resource.DisplayWindow(1).Type = 'Verasonics';
Resource.DisplayWindow(1).numFrames = 20;
Resource.DisplayWindow(1).AxesUnits = 'mm';
Resource.DisplayWindow(1).Colormap = gray(256);

% Specify Transmit waveform structure.
% All core waveform and TX setting are removed

% Specify TGC Waveform structure.
TGC.CntrlPts = [0, 271, 498, 617, 767, 903, 1000, 1023];
TGC.rangeMax = P.endDepth;
TGC.Waveform = computeTGCWaveform(TGC);

% Specify Receive structure arrays -
%   endDepth - add additional acquisition depth to account for some channels
%              having longer path lengths.
maxAcqLength = ceil(sqrt(P.endDepth^2 + ((Trans.numelements-1)*Trans.spacing)^2));

Receive = repmat(struct('Apod', zeros(1,Trans.numelements), ...
                        'aperture', 1, ...
                        'startDepth', P.startDepth, ...
                        'endDepth',maxAcqLength, ...
                        'TGC', 1, ...
                        'bufnum', 1, ...
                        'framenum', 1, ...
                        'acqNum', 1, ...
                        'sampleMode', 'NS200BW', ...
                        'mode', 0, ...
                        'callMediaFunc', 0),1, na*Resource.RcvBuffer(1).numFrames+3*na*Resource.RcvBuffer(2).numFrames);
% - Set event specific Receive attributes.
for i = 1:Resource.RcvBuffer(1).numFrames  % 128 acquisitions per frame
    k = na*(i-1);
    Receive(k+1).callMediaFunc = 1;
    for j = 1:na
        Receive(k+j).Apod(1:128) = 1.0;
        Receive(k+j).aperture = Paper(1); % Use aperture previously calculated in Paper
        Receive(k+j).framenum = i;
        Receive(k+j).acqNum = j;

    end
end

shiftRcv = na*(Resource.RcvBuffer(1).numFrames-1)+na;
rcvIDX = 0;

for i = 1:Resource.RcvBuffer(2).numFrames
        for j = 1:3:3*na

            rcvIDX = rcvIDX + 1;
            Receive(shiftRcv+rcvIDX).Apod(1:128) = 1.0;
            Receive(shiftRcv+rcvIDX).aperture = Paper(1);
            Receive(shiftRcv+rcvIDX).bufnum = 2;
            Receive(shiftRcv+rcvIDX).framenum = i;
            Receive(shiftRcv+rcvIDX).acqNum = j;

            rcvIDX = rcvIDX + 1;
            Receive(shiftRcv+rcvIDX).Apod(1:128) = 1.0;
            Receive(shiftRcv+rcvIDX).aperture = Paper(1);
            Receive(shiftRcv+rcvIDX).bufnum = 2;
            Receive(shiftRcv+rcvIDX).framenum = i;
            Receive(shiftRcv+rcvIDX).acqNum = j+1;

            rcvIDX = rcvIDX + 1;
            Receive(shiftRcv+rcvIDX).Apod(1:128) = 1.0;
            Receive(shiftRcv+rcvIDX).aperture = Paper(1);
            Receive(shiftRcv+rcvIDX).bufnum = 2;
            Receive(shiftRcv+rcvIDX).framenum = i;
            Receive(shiftRcv+rcvIDX).acqNum = j+2;

        end
end

% Specify Recon structure arrays.
Recon = struct('senscutoff', 0.5, ...
               'pdatanum', 1, ...
               'rcvBufFrame', -1, ...     % use most recently transferred frame
               'IntBufDest', [1,1], ...
               'ImgBufDest', [1,-1], ...  % auto-increment ImageBuffer each recon
               'RINums', 1:na);

% Define ReconInfo structures.
ReconInfo = repmat(struct('mode', 'accumIQ', ...  % accumulate IQ data.
                   'txnum', 1, ...
                   'rcvnum', 1, ...
                   'scaleFactor', 2.0, ...
                   'regionnum', 1), 1, na);
% - Set specific ReconInfo attributes.

if na > 1
    ReconInfo(1).mode = 'replaceIQ';  % replace IQ data
    for j = 1:na
        ReconInfo(j).txnum = j;
        ReconInfo(j).rcvnum = j;

    end
    ReconInfo(na).mode = 'accumIQ_replaceIntensity';  % accumulate & detect IQ data.
else
    ReconInfo(1).mode = 'replaceIntensity';
end

% Specify Process structure array.
pers = 20;
Process(1).classname = 'Image';
Process(1).method = 'imageDisplay';
Process(1).Parameters = {'imgbufnum',1,...   % number of buffer to process.
                         'framenum',-1,...   % (-1 => lastFrame)
                         'pdatanum',1,...    % number of PData structure to use
                         'pgain',10.0,...            % pgain is image processing gain
                         'reject',2,...      % reject level
                         'persistMethod','simple',...
                         'persistLevel',pers,...
                         'interpMethod','4pt',...
                         'grainRemoval','none',...
                         'processMethod','none',...
                         'averageMethod','none',...
                         'compressMethod','power',...
                         'compressFactor',40,...
                         'mappingMethod','full',...
                         'display',1,...      % display image after processing
                         'displayWindow',1};


Process(2).classname = 'External';
Process(2).method = 'move3dstage'; % save in multiple files   
Process(2).Parameters = {};

% Process(3).classname = 'External';
% Process(3).method = 'saveRF_dbz_fast'; % save in multiple files   
% Process(3).Parameters = {'srcbuffer','receive',... % name of buffer to process.
%     'srcbufnum',2,...
%     'srcframenum',-1,...
%     'dstbuffer','none'};
% 
% Process(3).classname = 'Image';
% Process(3).method = 'imageDisplay';
% Process(3).Parameters = {'imgbufnum',2,...   % number of buffer to process.
%                          'framenum',-1,...   % (-1 => lastFrame)
%                          'pdatanum',1,...    % number of PData structure to use
%                          'pgain',10.0,...            % pgain is image processing gain
%                          'reject',2,...      % reject level
%                          'persistMethod','simple',...
%                          'persistLevel',pers,...
%                          'interpMethod','4pt',...
%                          'grainRemoval','none',...
%                          'processMethod','none',...
%                          'averageMethod','none',...
%                          'compressMethod','power',...
%                          'compressFactor',40,...
%                          'mappingMethod','full',...
%                          'display',1,...      % display image after processing
%                          'displayWindow',1};

% Specify SeqControl structure arrays.
SeqControl(1).command = 'jump'; % jump back to start.
SeqControl(1).argument = 1;
SeqControl(2).command = 'timeToNextAcq';  % time between synthetic aperture acquisitions
SeqControl(2).argument = 400;  % 200 usec
SeqControl(3).command = 'timeToNextAcq';  % time between frames
SeqControl(3).argument = 20000 - (na-1)*200;  % 20 msec
SeqControl(4).command = 'returnToMatlab';

SeqControl(5).command = 'sync';
SeqControl(5).argument = 0.01e6; % unit:us
% SeqControl(5).command = 'jump'; % jump back to start.
% SeqControl(5).argument = 1292;

SeqControl(6).command = 'timeToNextAcq';  % time between synthetic aperture acquisitions
SeqControl(6).argument = 1e6;  % usec
SeqControl(7).command = 'timeToNextAcq';  % time between frames
SeqControl(7).argument = 20000 - (na-1)*200;  % 20 msec
SeqControl(8).command = 'waitForTransferComplete';
SeqControl(8).argument = 10;
SeqControl(9).command = 'markTransferProcessed';
SeqControl(9).argument = 10;

%SeqControl(10).command = 'transferToHost'; % transfer frame to host buffer
      %nsc = nsc+1;
nsc = length(SeqControl)+1; % nsc is count of SeqControl objects

%% bmode real time
n = 1; % n is count of Events
nStart_realtime = n;

% Acquire all frames defined in RcvBuffer
for i = 1:Resource.RcvBuffer(1).numFrames
    k = na*(i-1);
    for j = 1:na
        Event(n).info = 'first aperture.';
        Event(n).tx = j;
        Event(n).rcv = k+j;
        Event(n).recon = 0;
        Event(n).process = 0;
        Event(n).seqControl = 2;
        n = n+1;
    end
    %Event(n-1).seqControl = [3,nsc]; % use SeqControl structs defined below.
    Event(n-1).seqControl = [3,nsc];
    SeqControl(nsc).command = 'transferToHost';
    nsc = nsc + 1;

    Event(n).info = 'Reconstruct & process';
    Event(n).tx = 0;
    Event(n).rcv = 0;
    Event(n).recon = 1;
    Event(n).process = 1;
    Event(n).seqControl = 0;
%     if floor(i/2) == i/2     % Exit to Matlab every 2nd frame
%         Event(n).seqControl = 3;
%     end
    n = n+1;
    if floor(i/5) == i/5     % Exit to Matlab every 5th frame
        Event(n).info = 'ReturnToMatlab';
        Event(n).tx = 0;
        Event(n).rcv = 0;
        Event(n).recon = 0;
        Event(n).process = 0;
        Event(n).seqControl = 4;    
        n = n+1;
    else
        Event(n).seqControl = 0;
    end
end

Event(n).info = 'Jump back to first event';
Event(n).tx = 0;
Event(n).rcv = 0;
Event(n).recon = 0;
Event(n).process = 0;
Event(n).seqControl = 1;

n = n+1;
%% stage move batch
nstart_move = n;
%global loc
for ii = 1:loc_num
    %Resource.RcvBuffer(2).numFrames
    
    %loc = ii;
    Event(n).info = 'call ExtFun to move stage';
    Event(n).tx = 0;        %use ith TX structure.
    Event(n).rcv = 0;   
    Event(n).recon = 0;      % no reconstruction.
    Event(n).process = 2;    % no processing
    Event(n).seqControl = 5;%5; % seqCntrl 
    n = n+1;

%for fii = 1:Resource.RcvBuffer(2).numFrames
    for jj = 1:na               % Acquire frames for each fire

        Event(n).info = 'Acquisition single';
        Event(n).tx = na+3*jj-2;
        Event(n).rcv = na*Resource.RcvBuffer(1).numFrames+3*na*(ii-1)+3*jj-2;
        %Event(n).rcv = m*(i-1)+j;
        Event(n).recon = 0;
        Event(n).process = 0;
        Event(n).seqControl = 2;
        n = n+1;

        Event(n).info = 'Acquisition cdw1';
        Event(n).tx = na+3*jj-1;
        Event(n).rcv = na*Resource.RcvBuffer(1).numFrames+3*na*(ii-1)+3*jj-1;
        %Event(n).rcv = m*(i-1)+j;
        Event(n).recon = 0;
        Event(n).process = 0;
        Event(n).seqControl = 2;
        n = n+1;

        Event(n).info = 'Acquisition cdw2';
        Event(n).tx = na+3*jj;
        Event(n).rcv = na*Resource.RcvBuffer(1).numFrames+3*na*(ii-1)+3*jj;
        %Event(n).rcv = m*(i-1)+j;
        Event(n).recon = 0;
        Event(n).process = 0;
        Event(n).seqControl = 2;
        n = n+1;

    end
%end
    Event(n-1).seqControl = [7,3,nsc]; % modify last acquisition Event's seqControl

    SeqControl(nsc).command = 'transferToHost'; % transfer frame to host buffer
    nsc = nsc+1;
    %     Event(n-1).seqControl = [nsc]; % modify last acquisition Event's seqControl
%     Event(n).info = 'external save';
%     Event(n).tx = 0;        %use ith TX structure.
%     Event(n).rcv = 0;   
%     Event(n).recon = 0;      % no reconstruction.
%     Event(n).process = 3;    % no processing
%     Event(n).seqControl = 5; % seqCntrl 
%     n = n+1;
%     SeqControl(nsc).command = 'transferToHost'; % transfer frame to host buffer
%       nsc = nsc+1;

%     Event(n).info = 'external save';
%     Event(n).tx = 0;        %use ith TX structure.
%     Event(n).rcv = 0;   
%     Event(n).recon = 0;      % no reconstruction.
%     Event(n).process = 3;    % no processing
%     Event(n).seqControl = [8,9]; % seqCntrl 
%     n = n+1;

%     Event(n).info = 'recon and process';
%     Event(n).tx = 0;
%     Event(n).rcv = 0;
%     Event(n).recon = 1;
%     Event(n).process = 1;
%     Event(n).seqControl = 0;
%     n = n+1;

%     Event(n).info = 'external save';
%     Event(n).tx = 0;        %use ith TX structure.
%     Event(n).rcv = 0;   
%     Event(n).recon = 0;      % no reconstruction.
%     Event(n).process = 3;    % no processing
%     Event(n).seqControl = 5; % seqCntrl 
%     n = n+1;
    
%     Event(n).info = 'ReturnToMatlab';
%     Event(n).tx = 0;
%     Event(n).rcv = 0;
%     Event(n).recon = 0;
%     Event(n).process = 0;
%     Event(n).seqControl = 4;    
%     n = n+1;

   % if floor(ii/5) == ii/5    % Exit to Matlab every 5th frame
        
%         Event(n).info = 'recon_ReturnToMatlab';
%         Event(n).tx = 0;
%         Event(n).rcv = 0;
%         Event(n).recon = 0;
%         Event(n).process = 0;
%         Event(n).seqControl = 5;    
%         n = n+1;

%     else
%         Event(n).seqControl = 0;
%     end

%     Event(n).info = 'syn';
%     Event(n).tx = 0;        %use ith TX structure.
%     Event(n).rcv = 0;   
%     Event(n).recon = 0;      % no reconstruction.
%     Event(n).process = 0;    % no processing
%     Event(n).seqControl = [5]; % seqCntrl 
%     n = n+1;

end

% calllib('FMC40300x2DDll', 'FMC4030_Close_Device', 0)
% %Release Library
% unloadlibrary('FMC40300x2DDll')

% Event(n).info = 'Jump back to first event';
% Event(n).tx = 0;
% Event(n).rcv = 0;
% Event(n).recon = 0;
% Event(n).process = 0;
% Event(n).seqControl = 1;
% 
% n = n+1;

%% UI
% User specified UI Control Elements
% - Sensitivity Cutoff
UI(1).Control =  {'UserB7','Style','VsSlider','Label','Sens. Cutoff',...
                  'SliderMinMaxVal',[0,1.0,Recon(1).senscutoff],...
                  'SliderStep',[0.025,0.1],'ValueFormat','%1.3f'};
UI(1).Callback = text2cell('%SensCutoffCallback');

% - Range Change
MinMaxVal = [64,300,P.endDepth]; % default unit is wavelength
AxesUnit = 'wls';
if isfield(Resource.DisplayWindow(1),'AxesUnits')&&~isempty(Resource.DisplayWindow(1).AxesUnits)
    if strcmp(Resource.DisplayWindow(1).AxesUnits,'mm');
        AxesUnit = 'mm';
        MinMaxVal = MinMaxVal * (Resource.Parameters.speedOfSound/1000/Trans.frequency);
    end
end
UI(2).Control = {'UserA1','Style','VsSlider','Label',['Range (',AxesUnit,')'],...
                 'SliderMinMaxVal',MinMaxVal,'SliderStep',[0.1,0.2],'ValueFormat','%3.0f'};
UI(2).Callback = text2cell('%RangeChangeCallback');

% -Execute push button
UI(3).Control = {'UserC2','Style','VsPushButton','Label','SaveRF'};
UI(3).Callback = text2cell('%SaveCallback');

% % -Execute move button
% UI(4).Control = {'UserB2','Style','VsSlider','Label','linear stage pos','SliderMinMaxVal',[-30,30,0],...
%     'SliderStep',[0.025,0.1],'ValueFormat','%1.3f'};
% UI(4).Callback = @movelinearstage;
%{'assignin(''base'',''myPlotChnl'',UIValue)'};
% -Execute move button
UI(4).Control = {'UserB2','Style','VsSlider','Label','linear stage pos','SliderMinMaxVal',[-80,80,0],...
    'SliderStep',[0.025,0.1],'ValueFormat','%1.3f'};
UI(4).Callback = text2cell('%MoveCallback');

% -Execute push button for batch move
UI(5).Control = {'UserC3','Style','VsPushButton','Label','move batch'};
UI(5).Callback = text2cell('%MoveBatchSaveCallback');


% Specify factor for converting sequenceRate to frameRate.
frameRateFactor = 1;

% Add Vantage root to path so VSX can be found, then cd there as required
vantage_root = 'C:\Users\Administrator\Documents\VantageNXT-2.1.0';
setupLog(sprintf('Vantage root exists: %d', isfolder(vantage_root)));
assert(isfolder(vantage_root), 'Vantage root not found: %s', vantage_root);
addpath(vantage_root);
cd(vantage_root);
setupLog(sprintf('cwd: %s  VSX.m found: %d', pwd, isfile(fullfile(vantage_root,'VSX.m'))));

% Save sequence to MatFiles in the Vantage root (VSX looks here)
if ~isfolder('MatFiles'), [~,~] = mkdir('MatFiles'); end
setupLog('Saving .mat file...');
% Exclude guiLog: it's a handle to a nested function inside
% ScanControlPanel, so saving it captures the whole GUI figure in this
% .mat file — when VSX loads it back, that re-creates a frozen "ghost"
% copy of the Scan Control Panel window.
save('MatFiles/L38-22vfalsh_3d_cdw', '-regexp', '^(?!guiLog$).');
setupLog('Calling VSX...');
filename = 'MatFiles/L38-22vfalsh_3d_cdw'; VSX;
setupLog('VSX returned (closed)');
return

% **** Callback routines to be converted by text2cell function. ****
%SensCutoffCallback - Sensitivity cutoff change
ReconL = evalin('base', 'Recon');
for i = 1:size(ReconL,2)
    ReconL(i).senscutoff = UIValue;
end
assignin('base','Recon',ReconL);
Control = evalin('base','Control');
if isempty(Control(1).Command), n=1; else, n=length(Control)+1; end
Control(n).Command = 'update&Run';
Control(n).Parameters = {'Recon'};
assignin('base','Control', Control);
return
%SensCutoffCallback

%RangeChangeCallback - Range change
simMode = evalin('base','Resource.Parameters.simulateMode');
% No range change if in simulate mode 2.
if simMode == 2
    set(hObject,'Value',evalin('base','P.endDepth'));
    return
end
Trans = evalin('base','Trans');
Resource = evalin('base','Resource');
scaleToWvl = Trans.frequency/(Resource.Parameters.speedOfSound/1000);

P = evalin('base','P');
P.endDepth = UIValue;
if isfield(Resource.DisplayWindow(1),'AxesUnits')&&~isempty(Resource.DisplayWindow(1).AxesUnits)
    if strcmp(Resource.DisplayWindow(1).AxesUnits,'mm');
        P.endDepth = UIValue*scaleToWvl;
    end
end
assignin('base','P',P);

evalin('base','PData(1).Size(1) = ceil((P.endDepth-P.startDepth)/PData(1).PDelta(3));');
evalin('base','PData(1).Region = computeRegions(PData(1));');
evalin('base','Resource.DisplayWindow(1).Position(4) = ceil(PData(1).Size(1)*PData(1).PDelta(3)/Resource.DisplayWindow(1).pdelta);');
Receive = evalin('base', 'Receive');
maxAcqLength = ceil(sqrt(P.endDepth^2 + ((Trans.numelements-1)*Trans.spacing)^2));
for i = 1:size(Receive,2)
    Receive(i).endDepth = maxAcqLength;
end
assignin('base','Receive',Receive);
evalin('base','TGC.rangeMax = P.endDepth;');
evalin('base','TGC.Waveform = computeTGCWaveform(TGC);');
Control = evalin('base','Control');
if isempty(Control(1).Command), n=1; else, n=length(Control)+1; end
Control(n).Command = 'update&Run';
Control(n).Parameters = {'PData','InterBuffer','ImageBuffer','DisplayWindow','Receive','TGC','Recon'};
assignin('base','Control', Control);
assignin('base', 'action', 'displayChange');
return
%RangeChangeCallback


%MoveCallback
URB_Ojt = instrfind;
disp(UIValue)

ele_dis = UIValue;
assignin('base','linear_dis',ele_dis);
% Create the serial port object if it does not exist
% otherwise use the object that was found.
if isempty(URB_Ojt)==0
    fclose(URB_Ojt);
    delete(URB_Ojt)
%     URB_Ojt = URB_Ojt(1);
end
% URB_Ojt=serial('COM1','BaudRate',19200,'DataBits',8,'FlowControl','software','Terminator','CR/LF');
URB_Ojt=serial('COM1','BaudRate',19200,'DataBits',8,'Terminator','CR/LF');
%URB_Ojt=serial('/dev/ttyS0','BaudRate',19200,'DataBits',8,'Terminator','CR/LF');

fopen(URB_Ojt); %URB100CC_PN:B141539_UD:14/10/2013:
fprintf(URB_Ojt,'1VA10'); % 1VAnn: set axis 1 veolocity to 10

    commond_dis = ['1pa',num2str(UIValue)];% mm
fprintf(URB_Ojt,commond_dis);% 1pann: set to nn='0' angle absolute
%pause(1);
%MoveCallback


%SaveCallback
saveRF_dbz_txt();
%SaveCallbackTrans


%MoveBatchSaveCallback

%assignin('base', 'freeze', 1);
nStart2 = evalin('base','nstart_move');
Control = evalin('base','Control');
if isempty(Control(1).Command), n=1; else n=length(Control)+1; end
Control(n).Command = 'set&Run';
Control(n).Parameters = {'Parameters',1,'startEvent',nStart2};
evalin('base',['Resource.Parameters.startEvent =',num2str(nStart2),';']);
assignin('base','Control',Control);
assignin('base', 'freeze', 1);
return

%MoveBatchSaveCallback

