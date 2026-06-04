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

[n_samples, n_elem, n_acq] = size(RFdata);
row_start = search_range(1);
row_end   = search_range(2);

surface_idx = zeros(n_elem, n_acq);

for ei = 1:n_acq
    for eli = 1:n_elem

        % Extract RF column for this element and acquisition
        rf_col = double(RFdata(row_start:row_end, eli, ei));

        % Envelope detection via Hilbert transform
        env = abs(hilbert(rf_col));

        % Find peak
        [peak_val, peak_loc] = max(env);

        if peak_val > threshold
            % Strong echo found → surface detected
            surface_idx(eli, ei) = peak_loc + row_start - 1;
        else
            % Weak echo → inherit from previous element
            if eli > 1
                surface_idx(eli, ei) = surface_idx(eli-1, ei);
            else
                surface_idx(eli, ei) = round(mean(search_range));
            end
        end

    end
end
end