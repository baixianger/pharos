// Grok Bot mockup avatar mounting, gaze and accent mapping.
(() => {
  const { createAvatar, appearance, colors, pointerGaze } = window.grokAvatar;
  const motion = matchMedia("(prefers-reduced-motion: reduce)");
  const palettes = {"light":{"black":{"primary":"#1c1c1c","bubble":"#1c1c1cff"},"brown":{"primary":"#9d6937","bubble":"#86592e"},"red":{"primary":"#e72e3b","bubble":"#c82532"},"orange":{"primary":"#ee620d","bubble":"#d2550a"},"yellow":{"primary":"#da830e","bubble":"#c2730b"},"green":{"primary":"#10ab61","bubble":"#0d9655"},"cyan":{"primary":"#10a693","bubble":"#0d9381"},"blue":{"primary":"#1680f3","bubble":"#126fd4"},"violet":{"primary":"#8351e4","bubble":"#7442d1"},"magenta":{"primary":"#e52f8b","bubble":"#c82779"},"gray":{"primary":"#1c1c1c","bubble":"#1c1c1cff"}},"dark":{"black":{"primary":"#f5f5f5","bubble":"#f5f5f52e"},"brown":{"primary":"#8c5d31","bubble":"#8c5d31"},"red":{"primary":"#cf2b35","bubble":"#cf2b35"},"orange":{"primary":"#cd5309","bubble":"#cd5309"},"yellow":{"primary":"#c8770c","bubble":"#c8770c"},"green":{"primary":"#0e9f5a","bubble":"#0e9f5a"},"cyan":{"primary":"#0e9886","bubble":"#0e9886"},"blue":{"primary":"#116dd2","bubble":"#116dd2"},"violet":{"primary":"#7845d7","bubble":"#7845d7"},"magenta":{"primary":"#cf297e","bubble":"#cf297e"},"gray":{"primary":"#f5f5f5","bubble":"#f5f5f52e"}}};
  let sequence = 0;

  window.pharosAvatars = {
    shapes: ["sphere", "cloud", "square", "sparkle", "clover", "heartChubby", "starFlower", "teardrop", "tablet", "wedge", "house", "star6", "hex"],
    colors,
    palette: (color, theme) => palettes[theme][color] ?? palettes[theme].black,
    mount(host, settings) {
      const ink = ({ color, theme }) => appearance((colors[color] ?? colors.black)[theme]);
      const avatar = createAvatar({
        id: "pharos-avatar-" + (++sequence), seed: settings.seed, body: settings.shape,
        state: settings.state, size: settings.size, fill: .92,
        appearance: ink(settings), isStatic: motion.matches, isPlaying: settings.playing && !motion.matches,
        isFollowingPointer: false, maxFrameRate: 60
      });
      const canvas = document.createElement("div");
      host.replaceChildren(canvas);
      const detach = avatar.attach({ host, canvas });
      const scope = host.closest(".gb-bot,.gb-mainbot,.gb-chat-pill,.gb-profile,.gb-shape-choice,.gb-message-author") ?? host;
      const move = event => {
        if (!motion.matches) avatar.gaze(pointerGaze(host.getBoundingClientRect(), { x: event.clientX, y: event.clientY }, .5));
      };
      const leave = () => avatar.gaze(null);
      const reduce = () => avatar.update({ isStatic: motion.matches, isPlaying: settings.playing && !motion.matches });
      scope.addEventListener("pointermove", move, { passive: true });
      scope.addEventListener("pointerleave", leave);
      motion.addEventListener("change", reduce);
      return {
        update(next) {
          settings = next;
          avatar.update({
            body: next.shape, state: next.state, appearance: ink(next),
            isPlaying: next.playing && !motion.matches
          });
        },
        spin: () => { if (!motion.matches) avatar.poke("spin"); },
        detach() {
          motion.removeEventListener("change", reduce);
          scope.removeEventListener("pointermove", move);
          scope.removeEventListener("pointerleave", leave);
          detach();
        }
      };
    }
  };
})();
