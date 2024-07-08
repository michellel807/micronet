document.addEventListener("DOMContentLoaded", function() {
  var logoutLink = document.getElementById("logout-link");
  logoutLink.addEventListener("click", function(event) {
    event.preventDefault();
    if (confirm("Are you sure you want to logout?")) {
      var form = document.createElement("form");
      form.method = "POST";
      form.action = logoutLink.href;

      var csrfTokenInput = document.createElement("input");
      csrfTokenInput.type = "hidden";
      csrfTokenInput.name = "authenticity_token";
      csrfTokenInput.value = Rails.csrfToken();

      var methodInput = document.createElement("input");
      methodInput.type = "hidden";
      methodInput.name = "_method";
      methodInput.value = "DELETE";

      form.appendChild(csrfTokenInput);
      form.appendChild(methodInput);
      document.body.appendChild(form);
      form.submit();
    }
  });
});

