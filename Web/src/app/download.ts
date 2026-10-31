// Hands a file to the browser's own download, the one way to save a file that works in every browser.
export function downloadFile(file: File): void {
  const url = URL.createObjectURL(file);
  const link = document.createElement('a');
  link.href = url;
  link.download = file.name;
  document.body.append(link);
  link.click();
  link.remove();
  // Long enough for a slow phone to start the download; then the memory goes back.
  window.setTimeout(() => URL.revokeObjectURL(url), 30_000);
}
