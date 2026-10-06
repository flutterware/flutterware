for (const block of document.querySelectorAll('.code[data-copy]')) {
  const button = document.createElement('button');
  button.type = 'button';
  button.textContent = 'Copy';
  button.addEventListener('click', async () => {
    await navigator.clipboard.writeText(block.querySelector('code').innerText);
    button.textContent = 'Copied';
    setTimeout(() => (button.textContent = 'Copy'), 1500);
  });
  block.append(button);
}
