'use strict';

// Loaded last. The host starts sending messages as soon as it hears "ready", and each script's
// listener and functions must be in place by then, or the first document is lost.

document.execCommand('defaultParagraphSeparator', false, 'p');
ensureEditableLine();
post({ type: 'ready' });
