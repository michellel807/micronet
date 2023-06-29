<!DOCTYPE html>
<html>
<head>
  <title>Parameter page</title>
  <%= stylesheet_link_tag 'selectanalyses' %>
  <script src="https://code.jquery.com/jquery-3.6.0.min.js"></script>
  </head>
<body>
  <div class="selectanalyses">
    <header>
      <a href="https://genome.duke.edu/">
        <%= image_tag 'logo.png', alt: 'Duke Logo' %>
      </a>
      <h2 style="color:white;">THE SCHMID LAB MICROBIAL GROWTH MODEL</h2>
      <nav>
        <a class="wel_nav" href="/help">HELP</a>
        <a class="wel_nav" href="/resources">RESOURCES</a>
        <a class="wel_nav" href="/admin">ADMIN</a>
      </nav>
    </header>

    <div class="column skinny">
      <% content_for :title, "Parameters page" %>
      <h1>Select Analyses</h1>

      <p>Please select which analyses you would like to run. When you click "Start My Job," you will receive an email confirming that your jobs have begun. For more details on each analysis, please see the "Resources" tab.</p>

      <div class="general-white-block">
        <%= form_with url: '/generate', method: :post do |form| %>
          <h2 style="text-align: center;">Select Analyses</h2>
          <div class="analyses-container">
            <label>
              <%= check_box_tag 'chart_types[]', 'raw_data', @selected_chart_types.include?('raw_data') %>
              Raw Data Plot (Per Well)
            </label>
            <label style="display: inline-block; margin-right: 20px;margin-top: 10px;">
              <%= check_box_tag 'chart_types[]', 'fit_stats', @selected_chart_types.include?('fit_stats') %>
              Fit Statistics
            </label>
            <label style="display: inline-block; margin-right: 20px;margin-top: 10px;">
              <%= check_box_tag 'chart_types[]', 'compare-parameters', @selected_chart_types.include?('compare-parameters') %>
              Compare Parameters
            </label>
          </div>

          <div class="compare-parameters-container" style="display: none;">
            <label>Choose variable to compare on:</label>
            <% if @mapping_file_paths.present? %>
            <%= hidden_field_tag 'file_data', @file_data_json %>
            <%= select_tag 'column', options_for_select(@columns), prompt: 'Select a column', id: 'column' %>
          <% end %>
                   
  
            <div class="compare-options-container" style="display: none;">
              <label>Choose two to compare:</label>
              <%= select_tag 'condition1', '', prompt: 'Select a condition' %>
              <%= select_tag 'condition2', '', prompt: 'Select another condition' %>
            </div>
          </div>
          <div id="subset-dropdowns"></div> 
          <%= hidden_field_tag 'chart_types[]', @selected_chart_types %>

          <%= submit_tag 'Start My Job', class: 'analysis-button' %>
          <p style="margin-top: 10px;"> Note: Submitting may take a few seconds. Please be patient. </p>
        <% end %>
      </div>
    </div>

    <footer>
      <a href="https://duke.edu"><img src="https://software.duke.edu/sites/default/themes/slic/logo.svg" alt="Duke University Logo"/></a>
      <h2 style= "margin-top:10px">&copy; Schmid Lab 2023</h2>
      <br/>
    </footer>
  </div>

  <script>
  $(document).ready(function() {
    $("input[name='chart_types[]'][value='compare-parameters']").on("change", function() {
      if ($(this).is(":checked")) {
        $(".compare-parameters-container").show();
      } else {
        $(".compare-parameters-container").hide();
      }
    });

    $("#column").on("change", function() {
      var column = $(this).val();
      var options = <%= raw @data_file_paths.to_json %>;

      if (column) {
        var conditions = [];
        var fileData = JSON.parse($("#file_data").val());
        var rows = fileData.trim().split("\n");
        var header = rows.shift().split("\t");
        var columnIndex = header.indexOf(column);

        rows.forEach(function(row) {
          var values = row.split("\t");
          var condition = values[columnIndex];
          if (condition && !conditions.includes(condition)) {
            conditions.push(condition);
          }
        });

        $("#condition1, #condition2").empty();
        
        $("<option />").text("Select a condition").appendTo("#condition1");
        $("<option />").text("Select another condition").appendTo("#condition2");

        conditions.forEach(function(condition) {
          $("<option />").text(condition).appendTo("#condition1");
          $("<option />").text(condition).appendTo("#condition2");
        });

        $(".compare-options-container").show();

        // Generate subset dropdowns for remaining columns
        var remainingColumns = header.filter(function(col) {
          return col !== column;
        });

        var subsetDropdowns = $("#subset-dropdowns");
        subsetDropdowns.empty();

        $("<label />").text("Subset data so conditions can be directly compared:").appendTo(subsetDropdowns);

        remainingColumns.forEach(function(col) {
          var select = $("<select />").attr("name", col);
          $("<option />").text("Select a value for " + col).appendTo(select);

          rows.forEach(function(row) {
            var values = row.split("\t");
            var value = values[header.indexOf(col)];

            if (value && select.find("option[value='" + value + "']").length === 0) {
              $("<option />").text(value).val(value).appendTo(select);
            }
          });

          select.appendTo(subsetDropdowns);
        });
      } else {
        $(".compare-options-container").hide();
        $("#subset-dropdowns").empty();
      }
    });

    $("#condition1, #condition2").on("change", function() {
      var selectedConditions = [];
      selectedConditions.push($("#condition1").val());
      selectedConditions.push($("#condition2").val());

      // Remove the selected options from the other select elements
      $("#condition1, #condition2").not(this).find("option").each(function() {
        var optionValue = $(this).val();
        if (selectedConditions.includes(optionValue)) {
          $(this).prop("disabled", true);
        } else {
          $(this).prop("disabled", false);
        }
      });
    });
  });
</script>





</body>
</html>