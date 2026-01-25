// Renderer process script
// This file runs in the renderer process and has access to Node.js APIs

// Display version information
document.addEventListener('DOMContentLoaded', () => {
  // Get version info from process
  const electronVersion = process.versions.electron;
  const nodeVersion = process.versions.node;

  // Update version displays
  document.getElementById('electron-version').textContent = electronVersion;
  document.getElementById('node-version').textContent = nodeVersion;

  // Log initialization
  console.log('Azure Scripts UI initialized');
  console.log('Electron version:', electronVersion);
  console.log('Node.js version:', nodeVersion);
  console.log('Platform:', process.platform);

  // Add feature card interactions
  const featureCards = document.querySelectorAll('.feature-card');
  featureCards.forEach(card => {
    card.addEventListener('click', () => {
      console.log('Feature clicked:', card.querySelector('h4').textContent);
      // TODO: Implement feature-specific actions
    });
  });
});
