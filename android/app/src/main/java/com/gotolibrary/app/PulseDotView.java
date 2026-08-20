package com.gotolibrary.app;

import android.animation.ValueAnimator;
import android.content.Context;
import android.graphics.Canvas;
import android.graphics.Paint;
import android.util.AttributeSet;
import android.view.View;
import android.view.animation.LinearInterpolator;

/** Breathing status dot: solid core plus an expanding fading ring while active. */
public final class PulseDotView extends View {
    private static final long CYCLE_MS = 1400;

    private final Paint paint = new Paint(Paint.ANTI_ALIAS_FLAG);
    private int coreColor = 0xFF7FE2B9;
    private float phase;
    private ValueAnimator pulse;

    public PulseDotView(Context context) {
        super(context);
        init();
    }

    public PulseDotView(Context context, AttributeSet attrs) {
        super(context, attrs);
        init();
    }

    private void init() {
        pulse = ValueAnimator.ofFloat(0f, 1f);
        pulse.setDuration(CYCLE_MS);
        pulse.setRepeatCount(ValueAnimator.INFINITE);
        pulse.setInterpolator(new LinearInterpolator());
        pulse.addUpdateListener(animation -> {
            phase = animation.getAnimatedFraction();
            if (isShown()) invalidate();
        });
    }

    public void setTint(int color) {
        coreColor = color;
        invalidate();
    }

    public void setActive(boolean active) {
        if (active && !pulse.isStarted()) pulse.start();
        else if (!active) {
            pulse.cancel();
            phase = 0f;
        }
        invalidate();
    }

    @Override protected void onDetachedFromWindow() {
        pulse.cancel();
        super.onDetachedFromWindow();
    }

    @Override protected void onDraw(Canvas canvas) {
        super.onDraw(canvas);
        float size = Math.min(getWidth(), getHeight());
        if (size <= 0) return;
        float cx = getWidth() * .5f;
        float cy = getHeight() * .5f;
        float density = getResources().getDisplayMetrics().density;
        float core = 4.5f * density;

        if (pulse.isRunning()) {
            float spread = core + (size * .5f - core) * phase;
            int ringAlpha = Math.round(150 * (1f - phase));
            paint.setStyle(Paint.Style.STROKE);
            paint.setStrokeWidth(2f * density);
            paint.setColor((coreColor & 0x00FFFFFF) | (ringAlpha << 24));
            canvas.drawCircle(cx, cy, spread, paint);
            if (Math.abs(phase - 0f) > 0.01f) {
                float echo = core + (size * .5f - core) * Math.max(0f, phase - .5f) * 2f;
                int echoAlpha = Math.round(90 * (1f - Math.max(0f, phase - .5f) * 2f));
                if (echoAlpha > 0) {
                    paint.setColor((coreColor & 0x00FFFFFF) | (echoAlpha << 24));
                    canvas.drawCircle(cx, cy, echo, paint);
                }
            }
        }

        paint.setStyle(Paint.Style.FILL);
        paint.setColor(coreColor);
        canvas.drawCircle(cx, cy, core, paint);
        paint.setStyle(Paint.Style.STROKE);
        paint.setStrokeWidth(1f * density);
        paint.setColor(0x40FFFFFF);
        canvas.drawCircle(cx, cy, core + 1.5f * density, paint);
    }
}
