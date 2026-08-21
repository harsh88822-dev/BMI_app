# Website Support, Marketing, & Account Deletion Page Templates

When submitting your app, you must provide public URLs for Support and Marketing. These pages must be hosted on your website. 

Below are clean, ready-to-copy HTML and text templates for these pages.

---

## 1. Support Page Content (`support.html`)

This page must be reachable at a public URL (e.g., `https://www.yourdomain.com/support`) and is required by Apple App Review.

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Clockwork BMI - Customer Support</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; line-height: 1.6; color: #333; max-width: 800px; margin: 0 auto; padding: 20px; }
        h1 { color: #007aff; }
        h2 { color: #555; margin-top: 30px; }
        .contact-box { background: #f2f2f7; padding: 20px; border-radius: 8px; margin-top: 20px; }
        a { color: #007aff; text-decoration: none; }
        a:hover { text-decoration: underline; }
    </style>
</head>
<body>
    <h1>Clockwork BMI Support</h1>
    <p>Thank you for using Clockwork BMI (BMI 360 Camera). We are here to help you get the most out of your health and fitness scanning experience.</p>

    <h2>Frequently Asked Questions (FAQ)</h2>
    
    <h3>1. How do I perform an accurate body scan?</h3>
    <p>To get the most accurate results, place your mobile device on a stable surface at waist height. Step back 2-3 meters so your entire body (head to toe) is visible inside the camera frame. Follow the on-screen guides to rotate and capture the measurements.</p>

    <h3>2. Are my camera scans secure?</h3>
    <p>Yes. All scan videos are transmitted using encrypted HTTPS protocols to our secure cloud servers. We do not sell or share your video scans, and they are processed solely to estimate your height, weight, and BMI.</p>

    <h3>3. Why do I need to verify my identity?</h3>
    <p>Identity verification via a government-issued ID is used to prevent account spoofing, ensure profile ownership, and enforce age limits (users must be 18 or older).</p>

    <h2>Contact Us</h2>
    <div class="contact-box">
        <p>If you have questions, feedback, or need help with your account, please reach out to our support team:</p>
        <p><strong>Email Support:</strong> <a href="mailto:admin@clockworkpharmacy.com">admin@clockworkpharmacy.com</a> (cc: <a href="mailto:clockworkbmi@gmail.com">clockworkbmi@gmail.com</a>)</p>
        <p><strong>Support Numbers:</strong> +44 7745430512 or +44 (0) 2089867560</p>
        <p>We aim to respond to all inquiries within 24–48 hours.</p>
    </div>
</body>
</html>
```

---

## 2. Marketing / Landing Page Content (`index.html`)

Apple requires a **Marketing URL** where users can learn about the app features. It is typically your main landing page.

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Clockwork BMI - Camera-Based BMI Estimation</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; line-height: 1.6; color: #333; margin: 0; padding: 0; }
        .hero { background: linear-gradient(135deg, #007aff, #5856d6); color: white; text-align: center; padding: 80px 20px; }
        .hero h1 { margin: 0; font-size: 2.5em; }
        .hero p { font-size: 1.2em; margin-top: 10px; }
        .container { max-width: 1000px; margin: 0 auto; padding: 40px 20px; }
        .features { display: flex; flex-wrap: wrap; gap: 20px; margin-top: 40px; }
        .feature-card { flex: 1 1 300px; background: #f2f2f7; padding: 25px; border-radius: 12px; }
        .feature-card h3 { color: #007aff; margin-top: 0; }
        .disclaimer { font-size: 0.9em; color: #8e8e93; border-top: 1px solid #e5e5ea; margin-top: 50px; padding-top: 20px; }
        .footer { text-align: center; padding: 40px; color: #8e8e93; font-size: 0.9em; }
        a { color: #007aff; text-decoration: none; }
    </style>
</head>
<body>
    <div class="hero">
        <h1>Clockwork BMI</h1>
        <p>The contactless camera scanning tool to estimate height, weight, and BMI in seconds.</p>
    </div>

    <div class="container">
        <h2>Smart. Secure. Contactless.</h2>
        <p>No tape measures, no scale syncing. Just stand in front of your camera and get instant AI-guided estimations of your physical progress.</p>

        <div class="features">
            <div class="feature-card">
                <h3>Contactless Scanning</h3>
                <p>Advanced body segmentation and pose estimation algorithms estimate your height, weight, and BMI through a secure camera-guided sequence.</p>
            </div>
            <div class="feature-card">
                <h3>Progress History</h3>
                <p>Save and compare your metrics to monitor changes in your physical health and fitness journey over time.</p>
            </div>
            <div class="feature-card">
                <h3>Privacy First</h3>
                <p>Your scan videos are encrypted, secure, and used only to process calculations. We never sell your personal metrics.</p>
            </div>
        </div>

        <div class="disclaimer">
            <p><strong>Disclaimer:</strong> Clockwork BMI (BMI 360 Camera) is designed for general fitness and wellness monitoring purposes only. The app does not provide medical diagnoses, treatment, or advice. Always consult a medical professional before starting a new exercise or diet regimen, or if you have concerns about your physical health.</p>
        </div>
    </div>

    <div class="footer">
        <p>© 2026 ClockWork Pharmacy. All rights reserved.</p>
        <p>
            <a href="privacy.html">Privacy Policy</a> | 
            <a href="terms.html">Terms of Service</a> | 
            <a href="support.html">Support</a> | 
            <a href="delete-account.html">Account Deletion</a>
        </p>
    </div>
</body>
</html>
```

---

## 3. Account Deletion Page Content (`delete-account.html`)

This page is required for the **Account Deletion URL** field in both stores.

```html
<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Clockwork BMI - Request Account Deletion</title>
    <style>
        body { font-family: -apple-system, BlinkMacSystemFont, "Segoe UI", Roboto, Helvetica, Arial, sans-serif; line-height: 1.6; color: #333; max-width: 600px; margin: 0 auto; padding: 40px 20px; }
        h1 { color: #ff3b30; }
        .instruction-box { border-left: 4px solid #ff3b30; background: #fff5f5; padding: 15px; margin: 20px 0; }
        a { color: #007aff; text-decoration: none; }
    </style>
</head>
<body>
    <h1>Delete Your Clockwork BMI Account</h1>
    <p>We respect your privacy and provide simple mechanisms for you to delete your account and erase all associated data from our servers.</p>

    <h2>Method 1: Delete via the App (Recommended)</h2>
    <p>You can instantly delete your account directly in the mobile application by following these steps:</p>
    <ol>
        <li>Open the <strong>Clockwork BMI</strong> app.</li>
        <li>Navigate to the <strong>Account Settings</strong> or <strong>Profile</strong> menu.</li>
        <li>Select <strong>"Delete Account"</strong> at the bottom of the screen.</li>
        <li>Confirm your decision.</li>
    </ol>
    <p>This action is irreversible. All of your registration details, profile info, government ID uploads, raw video scans, and BMI progress history will be permanently deleted from our active production systems.</p>

    <h2>Method 2: Request Deletion via Email</h2>
    <div class="instruction-box">
        <p>If you have uninstalled the App or cannot log in, you can request that we delete your account for you.</p>
        <p>Please send an email to <a href="mailto:admin@clockworkpharmacy.com?subject=Clockwork%20BMI%20Account%20Deletion%20Request">admin@clockworkpharmacy.com</a> (cc: <a href="mailto:clockworkbmi@gmail.com?subject=Clockwork%20BMI%20Account%20Deletion%20Request">clockworkbmi@gmail.com</a>) with the subject line <strong>"Clockwork BMI Account Deletion Request"</strong>.</p>
        <p>In your email, please specify the <strong>phone number</strong> associated with the account you wish to delete. We will verify your request and purge all account records within 7 business days.</p>
    </div>
</body>
</html>
```
