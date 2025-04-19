let tg = window.Telegram.WebApp;

// Состояние приложения
let isDragging = false;
let startX = 0;
let startY = 0;
let currentX = 0;
let currentY = 0;
let currentScale = 1;
let startDistance = 0;
let videoFile = null;
let lastTouchTime = 0;
let lastScale = 1;
let isCropSaved = false;
let savedCropState = null;
const SCALE_SENSITIVITY = 0.008;
const MOVE_SENSITIVITY = 1;

// Элементы интерфейса
const selectScreen = document.getElementById('select-screen');
const cropScreen = document.getElementById('crop-screen');
const selectButton = document.getElementById('select-video');
const videoPreview = document.getElementById('video-preview');
const cropArea = document.getElementById('crop-area');
const cropHandle = document.querySelector('.crop-handle');
const playPauseButton = document.getElementById('play-pause');
const timeSlider = document.getElementById('time-slider');
const saveCropButton = document.getElementById('save-crop');
const confirmButton = document.getElementById('confirm-crop');

// Инициализация Telegram Web App
if (window.Telegram.WebApp.initData === '') {
    console.error('Telegram Web App не инициализирован правильно');
    document.body.innerHTML = '<div style="padding: 20px; color: red;">Ошибка: приложение должно быть открыто из Telegram</div>';
} else {
    console.log('Telegram Web App успешно инициализирован');
    console.log('InitData:', window.Telegram.WebApp.initData);
    tg.expand();
    tg.enableClosingConfirmation();
}

// Выбор видео
selectButton.addEventListener('click', () => {
    const input = document.createElement('input');
    input.type = 'file';
    input.accept = 'video/*';
    input.style.display = 'none';
    document.body.appendChild(input);

    input.addEventListener('change', (e) => {
        const file = e.target.files[0];
        if (file) {
            handleVideoSelect(file);
        }
        document.body.removeChild(input);
    });

    input.click();
});

// Обработка выбранного видео
function handleVideoSelect(file) {
    if (file.size > 100 * 1024 * 1024) {
        if (typeof tg.showAlert === 'function') {
            tg.showAlert('Файл слишком большой. Максимальный размер - 100 МБ');
        } else {
            alert('Файл слишком большой. Максимальный размер - 100 МБ');
        }
        return;
    }

    videoFile = file;
    const videoUrl = URL.createObjectURL(file);
    videoPreview.src = videoUrl;

    videoPreview.onloadedmetadata = () => {
        if (videoPreview.duration > 60) {
            if (typeof tg.showAlert === 'function') {
                tg.showAlert('Видео должно быть не длиннее 60 секунд');
            } else {
                alert('Видео должно быть не длиннее 60 секунд');
            }
            return;
        }

        selectScreen.classList.remove('active');
        cropScreen.classList.add('active');

        timeSlider.max = videoPreview.duration;
        timeSlider.value = 0;
        
        videoPreview.play();
        playPauseButton.querySelector('.play-icon').textContent = '⏸';

        // Сбрасываем состояние кропа
        currentX = 0;
        currentY = 0;
        currentScale = 1;
        isCropSaved = false;
        savedCropState = null;
        confirmButton.disabled = true;

        initializeVideoControls();
    };
}

// Инициализация контролов видео
function initializeVideoControls() {
    const videoWrapper = document.querySelector('.video-wrapper');

    // Воспроизведение/пауза
    playPauseButton.addEventListener('click', () => {
        if (videoPreview.paused) {
            videoPreview.play();
            playPauseButton.querySelector('.play-icon').textContent = '⏸';
        } else {
            videoPreview.pause();
            playPauseButton.querySelector('.play-icon').textContent = '▶';
        }
    });

    // Обновление слайдера времени
    videoPreview.addEventListener('timeupdate', () => {
        timeSlider.value = videoPreview.currentTime;
    });

    // Перемотка видео
    timeSlider.addEventListener('input', () => {
        videoPreview.currentTime = timeSlider.value;
    });

    // Зацикливание видео
    videoPreview.addEventListener('ended', () => {
        videoPreview.currentTime = 0;
        videoPreview.play();
    });

    // Обработчики для перемещения
    videoWrapper.addEventListener('touchstart', handleTouchStart, { passive: false });
    videoWrapper.addEventListener('touchmove', handleTouchMove, { passive: false });
    videoWrapper.addEventListener('touchend', handleTouchEnd);

    // Обработчики для масштабирования
    videoWrapper.addEventListener('touchstart', handlePinchStart, { passive: false });
    videoWrapper.addEventListener('touchmove', handlePinchMove, { passive: false });
    videoWrapper.addEventListener('touchend', handlePinchEnd);

    // Сохранение области кропа
    saveCropButton.addEventListener('click', () => {
        savedCropState = {
            x: currentX,
            y: currentY,
            scale: currentScale,
            time: videoPreview.currentTime
        };
        isCropSaved = true;
        confirmButton.disabled = false;
        
        if (typeof tg.showPopup === 'function') {
            tg.showPopup({
                title: 'Область сохранена',
                message: 'Теперь нажмите "Готово" для создания видеокружка',
                buttons: [{text: 'OK'}]
            });
        } else {
            alert('Область сохранена. Теперь нажмите "Готово" для создания видеокружка');
        }
    });
}

function handleTouchStart(e) {
    if (!isCropSaved && e.touches.length === 1) {
        isDragging = true;
        const touch = e.touches[0];
        startX = touch.clientX - currentX;
        startY = touch.clientY - currentY;
        e.preventDefault();
    }
}

function handleTouchMove(e) {
    if (!isCropSaved && isDragging && e.touches.length === 1) {
        const touch = e.touches[0];
        const deltaX = (touch.clientX - startX - currentX) * MOVE_SENSITIVITY;
        const deltaY = (touch.clientY - startY - currentY) * MOVE_SENSITIVITY;
        
        currentX += deltaX;
        currentY += deltaY;
        
        startX = touch.clientX - currentX;
        startY = touch.clientY - currentY;
        
        requestAnimationFrame(() => {
            updateVideoTransform();
        });
        e.preventDefault();
    }
}

function handleTouchEnd() {
    if (!isCropSaved) {
        isDragging = false;
    }
}

function handlePinchStart(e) {
    if (!isCropSaved && e.touches.length === 2) {
        const touch1 = e.touches[0];
        const touch2 = e.touches[1];
        startDistance = Math.hypot(
            touch1.clientX - touch2.clientX,
            touch1.clientY - touch2.clientY
        );
        e.preventDefault();
    }
}

function handlePinchMove(e) {
    if (!isCropSaved && e.touches.length === 2) {
        const touch1 = e.touches[0];
        const touch2 = e.touches[1];
        const currentDistance = Math.hypot(
            touch1.clientX - touch2.clientX,
            touch1.clientY - touch2.clientY
        );
        
        if (startDistance > 0) {
            const now = Date.now();
            const timeDelta = now - lastTouchTime;
            lastTouchTime = now;
            
            const scaleDelta = ((currentDistance / startDistance) - 1) * SCALE_SENSITIVITY * Math.min(timeDelta, 32);
            const newScale = Math.min(Math.max(currentScale + scaleDelta, 0.5), 3);
            
            if (Math.abs(newScale - lastScale) > 0.01) {
                currentScale = newScale;
                lastScale = newScale;
                requestAnimationFrame(() => {
                    updateVideoTransform();
                });
            }
        }
        e.preventDefault();
    }
}

function handlePinchEnd() {
    if (!isCropSaved) {
        startDistance = 0;
    }
}

function updateVideoTransform() {
    const transform = `translate(${currentX}px, ${currentY}px) scale(${currentScale})`;
    videoPreview.style.transform = transform;
}

// Обработка кнопки "Готово"
confirmButton.addEventListener('click', async () => {
    if (!videoFile) {
        if (typeof tg.showAlert === 'function') {
            tg.showAlert('Пожалуйста, выберите видео');
        } else {
            alert('Пожалуйста, выберите видео');
        }
        return;
    }

    if (!isCropSaved || !savedCropState) {
        if (typeof tg.showAlert === 'function') {
            tg.showAlert('Пожалуйста, сохраните выбранную область');
        } else {
            alert('Пожалуйста, сохраните выбранную область');
        }
        return;
    }

    if (typeof tg.showProgress === 'function') {
        tg.showProgress();
    }

    try {
        const video = document.getElementById('video-preview');
        const container = document.querySelector('.video-container');
        const cropFrame = document.querySelector('.crop-frame');
        
        // Получаем реальные размеры видео
        const videoWidth = video.videoWidth;
        const videoHeight = video.videoHeight;
        
        // Получаем текущие размеры и позицию видео в контейнере
        const rect = video.getBoundingClientRect();
        
        // Вычисляем масштаб видео относительно оригинального размера
        const scaleX = videoWidth / rect.width;
        const scaleY = videoHeight / rect.height;
        
        // Нормализуем координаты (0-1)
        const x = Math.max(0, Math.min(1, (-savedCropState.x * scaleX + videoWidth/2) / videoWidth));
        const y = Math.max(0, Math.min(1, (-savedCropState.y * scaleY + videoHeight/2) / videoHeight));

        const formData = new FormData();
        formData.append('video', videoFile);
        formData.append('cropData', JSON.stringify({
            x: x,
            y: y,
            width: cropFrame.offsetWidth * scaleX / savedCropState.scale,
            height: cropFrame.offsetHeight * scaleY / savedCropState.scale,
            currentTime: savedCropState.time || 0
        }));

        // Получаем chatId из initData
        try {
            const initDataStr = window.Telegram.WebApp.initData;
            const searchParams = new URLSearchParams(initDataStr);
            const dataStr = searchParams.get('user') || '{}';
            const data = JSON.parse(decodeURIComponent(dataStr));
            console.log('Parsed initData:', data);
            
            if (data.id) {
                formData.append('chatId', data.id.toString());
            } else {
                throw new Error('Не удалось получить идентификатор чата из user.id');
            }
        } catch (error) {
            console.error('Ошибка при получении chatId:', error);
            throw new Error('Не удалось получить идентификатор чата');
        }

        const response = await fetch('/api/upload', {
            method: 'POST',
            headers: {
                'ngrok-skip-browser-warning': 'true'
            },
            body: formData
        });

        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(errorText);
        }

        const result = await response.json();
        
        if (typeof tg.sendData === 'function') {
            tg.sendData(JSON.stringify(result));
        }
        if (typeof tg.close === 'function') {
            tg.close();
        }

    } catch (error) {
        console.error('Error:', error);
        if (typeof tg.showAlert === 'function') {
            tg.showAlert(error.message);
        } else {
            alert(error.message);
        }
    } finally {
        if (typeof tg.hideProgress === 'function') {
            tg.hideProgress();
        }
    }
}); 