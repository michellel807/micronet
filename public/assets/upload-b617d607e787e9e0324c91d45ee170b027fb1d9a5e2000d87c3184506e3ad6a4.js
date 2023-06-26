// app/assets/javascripts/upload.js

function updateFileName(input) {
  const fileName = input.files[0].name;
  const fileNameSpan = document.getElementById('file-name');
  fileNameSpan.textContent = fileName;
}
;
