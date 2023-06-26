function updateFileName(input) {
  var label = input.parentNode.querySelector('label');
  if (input.files.length > 0) {
    label.textContent = 'File chosen: ' + input.files[0].name;
  } else {
    label.textContent = 'No file chosen';
  }
}

