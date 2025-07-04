;(function (window, document) {
  'use strict';

  // throw an error if required globals not defined
  if (typeof API_BASE_URL === "undefined") {
    throw new Error("API_BASE_URL is required and is not defined");
  }
  if (typeof delayedCallback === "undefined") {
    throw new Error("delayedCallback() is required and is not defined");
  }

  // globals for this script
  var epgroup_select = $("#endpointgroups");
  var loading_spinner = $('#loading-spinner');
  var showallcalls_inp = $('#toggle_completed_calls');
  var date_start_inp = $('#date_start');
  var date_end_inp = $('#date_end');
  var cdr_table = null;

  /**
   * Show a spinner while loading
   * @param isLoading {boolean}
   */
  function changeLoadingState(isLoading) {
    if (isLoading) {
      loading_spinner.removeClass('hidden');
    }
    else {
      loading_spinner.addClass('hidden');
    }
  }

  /**
   * Get filtered CDR IDs for export
   * @returns {string}
   */
  function getFilteredCdrIds() {
    var value = $('#cdrs').DataTable().columns({ search: 'applied' }).data()[0];
    // Check if values were selected using the search field. 
    if (value != ",") {
      return value;
    }
    else {
      return '';
    }
  }

  /**
   * Format date for API consumption
   * @param {string|Date} date
   * @returns {string}
   */
  function formatDateForAPI(date) {
    if (!date) return '';
    
    if (typeof date === 'string') {
      return date;
    }
    
    // If it's a Date object, format it as YYYY-MM-DD
    return date.toISOString().split('T')[0];
  }

  /**
   * Get current date filter values
   * @returns {object}
   */
  function getDateFilters() {
    return {
      date_start: date_start_inp.val(),
      date_end: date_end_inp.val()
    };
  }

  /**
   * Validate date range
   * @returns {boolean}
   */
  function validateDateRange() {
    var startDate = date_start_inp.val();
    var endDate = date_end_inp.val();
    
    if (startDate && endDate) {
      if (new Date(startDate) > new Date(endDate)) {
        alert('Start date cannot be later than end date.');
        return false;
      }
    }
    
    return true;
  }

  /**
   * Load CDR DataTable with optional date filters
   * @param {string} gwgroupid
   */
  function loadCDRDataTable(gwgroupid) {
    if (!validateDateRange()) {
      return;
    }

    changeLoadingState(true);

    // Get date filters
    var dateFilters = getDateFilters();

    // load CDR data
    if ($.fn.dataTable.isDataTable(cdr_table)) {
      // Update URL and reload
      var apiUrl = API_BASE_URL + "cdrs/endpointgroups/" + gwgroupid;
      cdr_table.ajax.url(apiUrl);
      cdr_table.ajax.reload();
    }
    // datatable init
    else {
      cdr_table = $('#cdrs').DataTable({
        "pagingType": "full_numbers",
        "processing": false,
        "serverSide": true,
        "ajax": {
          "url": API_BASE_URL + "cdrs/endpointgroups/" + gwgroupid,
          "data": function (d) {
            d.nonCompletedCalls = showallcalls_inp.val() === '1';
            
            // Add date filters to request
            var dateFilters = getDateFilters();
            if (dateFilters.date_start) {
              d.date_start = dateFilters.date_start;
            }
            if (dateFilters.date_end) {
              d.date_end = dateFilters.date_end;
            }
            
            return d;
          },
          "dataFilter": function (data) {
            if (data) {
              var json = jQuery.parseJSON(data);
              json.recordsTotal = json.total_rows;
              json.recordsFiltered = json.filtered_rows;
              return JSON.stringify(json);
            }

            return JSON.stringify({
              data: [],
              recordsTotal: 0,
              recordsFiltered: 0
            });
          }
        },
        "columns": [
          {"data": "cdr_id", "orderable": false},
          {"data": "call_start_time"},
          {"data": "call_duration"},
          {"data": "call_direction"},
          {"data": "src_gwgroupid", "visible": false, "searchable": false},
          {"data": "src_gwgroupname"},
          {"data": "dst_gwgroupid", "visible": false, "searchable": false},
          {"data": "dst_gwgroupname"},
          {"data": "src_username"},
          {"data": "dst_username"},
          {"data": "src_address"},
          {"data": "dst_address"},
          {"data": "call_id", "orderable": false}
        ],
        "order": [[1, 'desc']],
        "pageLength": 100
      });

      // make searchbox less spammy
      var searchbox = $('#cdrs input[type="search"]');
      searchbox.unbind();
      searchbox.bind('input', delayedCallback(
        function(ev) {
          cdr_table.search(this.value).draw();
        }, 500)
      );
    }

    changeLoadingState(false);
  }

  /**
   * Apply date filters
   */
  function applyDateFilter() {
    var selectedGwGroup = epgroup_select.find('option:selected').val();
    
    if (!selectedGwGroup || selectedGwGroup === '0') {
      alert('Please select an endpoint group first.');
      return;
    }

    if (!validateDateRange()) {
      return;
    }

    var dateFilters = getDateFilters();
    
    if (!dateFilters.date_start && !dateFilters.date_end) {
      alert('Please select at least one date to filter.');
      return;
    }

    console.log('Applying date filter:', dateFilters);
    
    // Reload the table with new date filters
    loadCDRDataTable(selectedGwGroup);
  }

  /**
   * Clear date filters
   */
  function clearDateFilter() {
    date_start_inp.val('');
    date_end_inp.val('');
    
    var selectedGwGroup = epgroup_select.find('option:selected').val();
    if (selectedGwGroup && selectedGwGroup !== '0') {
      console.log('Date filter cleared');
      loadCDRDataTable(selectedGwGroup);
    }
  }

  /**
   * Set quick date filter
   * @param {string} period - 'today', 'week', 'month'
   */
  function setQuickDateFilter(period) {
    var today = new Date();
    var startDate, endDate;
    
    switch (period) {
      case 'today':
        startDate = endDate = formatDateForAPI(today);
        break;
        
      case 'week':
        var weekStart = new Date(today);
        weekStart.setDate(today.getDate() - today.getDay());
        startDate = formatDateForAPI(weekStart);
        endDate = formatDateForAPI(today);
        break;
        
      case 'month':
        var monthStart = new Date(today.getFullYear(), today.getMonth(), 1);
        startDate = formatDateForAPI(monthStart);
        endDate = formatDateForAPI(today);
        break;
    }
    
    date_start_inp.val(startDate);
    date_end_inp.val(endDate);
    
    // Auto-apply the filter
    applyDateFilter();
  }

  /**
   * Export CDRs with current filters
   */
  function exportCDRs() {
    var gwgroupid = $("#endpointgroups").val();
    
    if (!gwgroupid || gwgroupid === '0') {
      alert('Please select an endpoint group first.');
      return;
    }

    var filterIds = getFilteredCdrIds();
    var dateFilters = getDateFilters();

    // Show message to user
    alert('La exportación ha comenzado. Este proceso puede tardar varios minutos. Los archivos se guardarán en el servidor.');
    
    // AJAX call to start background export
    $.ajax({
      type: "POST",
      url: API_BASE_URL + 'cdrs/endpointgroups/' + gwgroupid + '/export',
      data: JSON.stringify({
        filter: filterIds,
        date_start: dateFilters.date_start,
        date_end: dateFilters.date_end,
        nonCompletedCalls: showallcalls_inp.val() === '1'
      }),
      contentType: "application/json; charset=utf-8",
      dataType: "json",
      success: function(response) {
        console.log('Export started successfully:', response.msg);
        if (response.export_id) {
          // Could implement export status tracking here
          console.log('Export ID:', response.export_id);
        }
      },
      error: function(xhr, status, error) {
        console.error("Error starting export:", error);
        var errorMsg = "Hubo un error al iniciar la exportación.";
        
        try {
          var response = JSON.parse(xhr.responseText);
          if (response.msg) {
            errorMsg = response.msg;
          }
        } catch (e) {
          // Use default error message
        }
        
        alert(errorMsg);
      }
    });
  }

  $(document).ready(function () {
    // Get endpoint group data
    $.ajax({
      type: "GET",
      url: API_BASE_URL + "endpointgroups",
      dataType: "json",
      contentType: "application/json; charset=utf-8",
      success: function (response, textStatus, jqXHR) {
        for (var i = 0; i < response.data.length; i++) {
          epgroup_select.append("<option value='" + response.data[i].gwgroupid + "'>" + response.data[i].name + "</option>");
        }
      },
      error: function(xhr, status, error) {
        console.error("Error loading endpoint groups:", error);
      }
    });

    // Default is enabled
    showallcalls_inp.bootstrapToggle('on');

    /* Event Listeners */

    // Completed calls toggle listener
    showallcalls_inp.change(function() {
      var self = $(this);

      if (self.is(":checked") || self.prop("checked")) {
        self.val(1);
      }
      else {
        self.val(0);
      }
      
      var selectedGwGroup = epgroup_select.find('option:selected').val();
      if (selectedGwGroup && selectedGwGroup !== '0') {
        loadCDRDataTable(selectedGwGroup);
      }
    });

    // Endpoint group change listener
    epgroup_select.change(function () {
      var selectedGwGroup = epgroup_select.find('option:selected').val();
      if (selectedGwGroup && selectedGwGroup !== '0') {
        loadCDRDataTable(selectedGwGroup);
      }
    });

    // Download/Export button listener
    $('#downloadCDR').click(exportCDRs);

    // Refresh button listener
    $('#refreshCDR').click(function () {
      var selectedGwGroup = epgroup_select.find('option:selected').val();
      if (selectedGwGroup && selectedGwGroup !== '0') {
        loadCDRDataTable(selectedGwGroup);
      }
    });

    // Date filter event listeners
    $('#applyDateFilter').click(applyDateFilter);
    $('#clearDateFilter').click(clearDateFilter);

    // Quick date filter buttons
    $('#todayFilter').click(function() {
      setQuickDateFilter('today');
    });

    $('#thisWeekFilter').click(function() {
      setQuickDateFilter('week');
    });

    $('#thisMonthFilter').click(function() {
      setQuickDateFilter('month');
    });

    // Date input change validation
    date_start_inp.add(date_end_inp).on('change', function() {
      validateDateRange();
    });

    // Auto-apply date filter when dates change (optional)
    date_start_inp.add(date_end_inp).on('change', delayedCallback(function() {
      var selectedGwGroup = epgroup_select.find('option:selected').val();
      if (selectedGwGroup && selectedGwGroup !== '0') {
        var dateFilters = getDateFilters();
        if (dateFilters.date_start || dateFilters.date_end) {
          // Auto-apply after a short delay
          // applyDateFilter();
        }
      }
    }, 1000));
  });

})(window, document);