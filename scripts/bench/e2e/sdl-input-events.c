/* SDL2-compat 2.32.58 cannot push SDL_TEXTINPUT. Construct SDL3 events with
 * its own headers; Lem still consumes them through the SDL2 event loop.
 * The caller resolves SDL_PushEvent from SDL3's explicit library handle to
 * avoid interposition by SDL2's identically named, incompatible function.
 * Keep this helper loaded until process exit: queued text refers to "x". */
#include <SDL3/SDL.h>
#include <string.h>

typedef bool (SDLCALL *PushEvent)(SDL_Event *event);

int lem_bench_push_key(Uint32 window_id, Uint8 key, PushEvent push_event)
{
    SDL_Event event;
    if (key != 'x' && key != '\b')
        return -1;
    memset(&event, 0, sizeof(event));
    event.type = SDL_EVENT_KEY_DOWN;
    event.key.windowID = window_id;
    event.key.down = true;
    event.key.scancode = key == 'x' ? SDL_SCANCODE_X : SDL_SCANCODE_BACKSPACE;
    event.key.key = key == 'x' ? SDLK_X : SDLK_BACKSPACE;
    if (!push_event(&event))
        return -1;
    if (key == 'x') {
        SDL_Event text;
        memset(&text, 0, sizeof(text));
        text.type = SDL_EVENT_TEXT_INPUT;
        text.text.windowID = window_id;
        text.text.text = "x";
        if (!push_event(&text))
            return -1;
    }
    event.type = SDL_EVENT_KEY_UP;
    event.key.down = false;
    return push_event(&event) ? 1 : -1;
}
