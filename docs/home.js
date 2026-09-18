// The mode picker and screen gallery work without JavaScript.
// Enhance ordinary recording links with an inline player when dialogs exist.
const journeyDialog = document.getElementById('journey-dialog');
if (journeyDialog && typeof journeyDialog.showModal === 'function') {
  const video = journeyDialog.querySelector('video');
  document.querySelectorAll('[data-watch]').forEach(link => {
    link.addEventListener('click', event => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey) return;
      event.preventDefault();
      journeyDialog.showModal();
    });
  });
  journeyDialog.addEventListener('close', () => video.pause());
  journeyDialog.addEventListener('click', event => {
    if (event.target !== journeyDialog) return;
    const bounds = journeyDialog.getBoundingClientRect();
    if (event.clientX < bounds.left || event.clientX > bounds.right ||
        event.clientY < bounds.top || event.clientY > bounds.bottom) journeyDialog.close();
  });
}
