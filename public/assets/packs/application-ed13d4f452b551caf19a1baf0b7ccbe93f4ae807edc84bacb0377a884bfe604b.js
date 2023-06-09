$(document).on("ajax:beforeSend", function () {
  $(".generating-message").show();
});

$(document).on("ajax:complete", function () {
  $(".generating-message").hide();
});

// app/javascript/packs/application.js

;
