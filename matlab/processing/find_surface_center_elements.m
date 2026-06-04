function surface_depth = find_surface_center_elements(RFdata, ...
                          search_range, threshold, center_half_width)
% Uses only center elements for faster, more reliable surface detection
% Center elements have flattest hyperbola → best SNR for flat surface

[~, n_elem, n_acq] = size(RFdata);

center     = round(n_elem / 2);
elem_range = (center - center_half_width):(center + center_half_width);
row_start  = search_range(1);
row_end    = search_range(2);

surface_depth = zeros(1, n_acq);

for ei = 1:n_acq
    % Sum RF across center elements → coherent compounding without beamforming
    % For a flat surface, all center elements see approximately same delay
    rf_sum = sum(double(RFdata(row_start:row_end, elem_range, ei)), 2);
    %             ↑ [window_length × 1]

    env = abs(hilbert(rf_sum));
    [peak_val, peak_loc] = max(env);

    if peak_val > threshold
        surface_depth(ei) = peak_loc + row_start - 1;
    else
        if ei > 1
            surface_depth(ei) = surface_depth(ei-1);
        else
            surface_depth(ei) = round(mean(search_range));
        end
    end
end
end