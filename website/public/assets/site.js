// How it works: on wide screens, pin a panel beside the steps and show the close-up of the step
// being read. Without this script, or on narrow screens, each step keeps its own close-up, so
// nothing depends on it running.
(() => {
  const story = document.querySelector('.story');
  if (!story || !('IntersectionObserver' in window)) return;
  const wide = window.matchMedia('(min-width: 900px)');
  const steps = [...story.querySelectorAll('.story-step')];
  const shots = [...story.querySelectorAll('.story-focus .focus')];
  let observer;

  const show = (index) => {
    steps.forEach((s, i) => s.classList.toggle('is-active', i === index));
    shots.forEach((p, i) => p.classList.toggle('is-active', i === index));
  };

  const enable = () => {
    show(0);
    shots.forEach((p) => { const img = p.querySelector('img'); if (img) img.loading = 'eager'; });
    story.classList.add('story-js');
    observer = new IntersectionObserver((entries) => {
      entries.forEach((e) => { if (e.isIntersecting) show(steps.indexOf(e.target)); });
    }, { rootMargin: '-45% 0px -45% 0px' });
    steps.forEach((s) => observer.observe(s));
  };

  const disable = () => {
    observer?.disconnect();
    story.classList.remove('story-js');
  };

  const update = () => (wide.matches ? enable() : disable());
  wide.addEventListener('change', update);
  update();
})();
