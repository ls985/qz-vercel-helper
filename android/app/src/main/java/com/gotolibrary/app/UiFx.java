package com.gotolibrary.app;

import android.view.MotionEvent;
import android.view.View;
import android.view.ViewGroup;
import android.view.animation.DecelerateInterpolator;

import java.util.ArrayList;
import java.util.List;

/** Tactile micro-interactions shared across the app. */
final class UiFx {
    private UiFx() {}

    /** Press-down scale + release spring. Listener returns false so clicks still fire. */
    static void attachPressFx(View... views) {
        for (View view : views) {
            view.setOnTouchListener((v, event) -> {
                if (!v.isEnabled()) return false;
                switch (event.getAction()) {
                    case MotionEvent.ACTION_DOWN:
                        v.animate().scaleX(.955f).scaleY(.955f).alpha(.88f)
                            .setDuration(110L).start();
                        break;
                    case MotionEvent.ACTION_UP:
                    case MotionEvent.ACTION_CANCEL:
                        v.animate().scaleX(1f).scaleY(1f).alpha(1f)
                            .setDuration(210L).start();
                        break;
                    default:
                        break;
                }
                return false;
            });
        }
    }

    /** Staggered rise-in for the main column's panel children. Runs once per attach. */
    static void playEntrance(ViewGroup column) {
        if (column == null) return;
        List<View> children = new ArrayList<>();
        for (int i = 0; i < column.getChildCount(); i++) children.add(column.getChildAt(i));
        float density = column.getResources().getDisplayMetrics().density;
        long delay = 0L;
        for (View child : children) {
            if (child.getVisibility() != View.VISIBLE) continue;
            child.setAlpha(0f);
            child.setTranslationY(22f * density);
            child.animate()
                .alpha(1f).translationY(0f)
                .setStartDelay(delay)
                .setDuration(460L)
                .setInterpolator(new DecelerateInterpolator(1.35f))
                .start();
            delay += 70L;
        }
    }
}
