function surface_idx = find_surface_rfdata(RFdata, search_range, threshold)
% find_surface_rfdata  Find wafer surface position from raw RF data.
%
% Uses envelope detection on each element independently,
% then searches for the peak reflection within a depth window.
%
% Inputs:
%   RFdata       [samples × elements × acquisitions]  raw RF
%   search_range [row_start, row_end]  sample index window to search
%   threshold    minimum envelope amplitude to accept as surface
%
% Output:
%   surface_idx  [elements × acquisitions]  surface sample index per element

[~, n_elem, n_acq] = size(RFdata);
row_start = search_range(1);
row_end   = search_range(2);

% Extract search window: [window_len × n_elem × n_acq]
window = double(RFdata(row_start:row_end, :, :));
window_len = row_end - row_start + 1;

% Reshape to [window_len × (n_elem*n_acq)] so hilbert runs on all columns
% at once — eliminates the double for-loop
cols   = reshape(window, window_len, n_elem * n_acq);
env    = abs(hilbert(cols));                        % one FFT batch

% Peak value and location per column
[peak_vals, peak_locs] = max(env, [], 1);           % [1 × n_elem*n_acq]

% Convert back to [n_elem × n_acq]
peak_vals = reshape(peak_vals, n_elem, n_acq);
peak_locs = reshape(peak_locs, n_elem, n_acq);

% Map local window index → absolute sample index
surface_idx = peak_locs + row_start - 1;

% Where signal is below threshold, inherit from previous element
% (same fallback logic as before, now vectorized across acquisitions)
fallback = round(mean(search_range));
for eli = 1:n_elem
    weak = peak_vals(eli, :) <= threshold;
    if any(weak)
        if eli == 1
            surface_idx(eli, weak) = fallback;
        else
            surface_idx(eli, weak) = surface_idx(eli-1, weak);
        end
    end
end
end
