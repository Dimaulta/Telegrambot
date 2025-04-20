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

// Элементы интерфейса
const selectScreen = document.getElementById('select-screen');
const cropScreen = document.getElementById('crop-screen');
const selectButton = document.getElementById('select-video');
const videoPreview = document.getElementById('video-preview');
const cropFrame = document.querySelector('.crop-frame');
const playPauseButton = document.getElementById('play-pause');
const timeSlider = document.getElementById('time-slider');
const cropButton = document.getElementById('crop-video');

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

// Обработка нажатий на кнопки
document.querySelectorAll('.button').forEach(button => {
    button.addEventListener('click', function() {
        this.classList.add('active');
    });
});

// Обработка выбора видео
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

// Функция для показа статусного сообщения
function showStatusMessage(message, duration = 4000) {
    const statusMessage = document.getElementById('status-message');
    statusMessage.textContent = message;
    statusMessage.classList.add('show');
    
    setTimeout(() => {
        statusMessage.classList.remove('show');
    }, duration);
}

// Обработка скроллинга для десктопа
let isScrolling = false;
let startScrollX = 0;
let startScrollY = 0;
let scrollLeft = 0;
let scrollTop = 0;

function initializeDesktopScroll() {
    const videoContainer = document.querySelector('.video-container');
    
    if (window.innerWidth >= 768) {
        videoContainer.addEventListener('mousedown', startScroll);
        window.addEventListener('mousemove', handleScroll);
        window.addEventListener('mouseup', stopScroll);
        window.addEventListener('mouseleave', stopScroll);
    }
}

function startScroll(e) {
    isScrolling = true;
    startScrollX = e.pageX - videoContainer.offsetLeft;
    startScrollY = e.pageY - videoContainer.offsetTop;
    scrollLeft = videoContainer.scrollLeft;
    scrollTop = videoContainer.scrollTop;
}

function handleScroll(e) {
    if (!isScrolling) return;
    e.preventDefault();
    
    const x = e.pageX - videoContainer.offsetLeft;
    const y = e.pageY - videoContainer.offsetTop;
    const walkX = (x - startScrollX) * 2;
    const walkY = (y - startScrollY) * 2;
    
    videoContainer.scrollLeft = scrollLeft - walkX;
    videoContainer.scrollTop = scrollTop - walkY;
}

function stopScroll() {
    isScrolling = false;
}

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
    videoPreview.classList.add('video-preview');

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
        
        // Автоматически воспроизводим видео
        videoPreview.play();
        playPauseButton.querySelector('.play-icon').textContent = '⏸';

        // Сбрасываем состояние
        currentX = 0;
        currentY = 0;
        currentScale = 1;
        updateVideoTransform();

        initializeVideoControls();
        initializeDesktopScroll();
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
}

function handleTouchStart(e) {
    if (e.touches.length === 1) {
        isDragging = true;
        const touch = e.touches[0];
        startX = touch.clientX - currentX;
        startY = touch.clientY - currentY;
        e.preventDefault();
    }
}

function handleTouchMove(e) {
    if (isDragging && e.touches.length === 1) {
        const touch = e.touches[0];
        currentX = touch.clientX - startX;
        currentY = touch.clientY - startY;
        updateVideoTransform();
        e.preventDefault();
    }
}

function handleTouchEnd() {
    isDragging = false;
}

function handlePinchStart(e) {
    if (e.touches.length === 2) {
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
    if (e.touches.length === 2) {
        const touch1 = e.touches[0];
        const touch2 = e.touches[1];
        const currentDistance = Math.hypot(
            touch1.clientX - touch2.clientX,
            touch1.clientY - touch2.clientY
        );
        
        if (startDistance > 0) {
            const scale = currentDistance / startDistance;
            currentScale = Math.min(Math.max(currentScale * scale, 0.5), 3);
            startDistance = currentDistance;
            updateVideoTransform();
        }
        e.preventDefault();
    }
}

function handlePinchEnd() {
    startDistance = 0;
}

function updateVideoTransform() {
    videoPreview.style.transform = `translate(${currentX}px, ${currentY}px) scale(${currentScale})`;
}

// Обработка кнопки "Обрезать"
cropButton.addEventListener('click', async () => {
    if (!videoFile) {
        if (typeof tg.showAlert === 'function') {
            tg.showAlert('Пожалуйста, выберите видео');
        } else {
            alert('Пожалуйста, выберите видео');
        }
        return;
    }

    try {
        showStatusMessage('Видео обрабатывается, оно появится в чате с этим ботом', 3000);

        const video = document.getElementById('video-preview');
        const videoRect = video.getBoundingClientRect();
        const cropRect = cropFrame.getBoundingClientRect();
        
        // Вычисляем относительные координаты (0-1) с учетом масштаба и позиции
        const videoWidth = videoRect.width / currentScale;
        const videoHeight = videoRect.height / currentScale;
        
        // Центр видео с учетом смещения
        const videoCenterX = videoRect.left + videoRect.width / 2;
        const videoCenterY = videoRect.top + videoRect.height / 2;
        
        // Центр области кропа
        const cropCenterX = cropRect.left + cropRect.width / 2;
        const cropCenterY = cropRect.top + cropRect.height / 2;
        
        // Относительное смещение центра кропа от центра видео
        const offsetX = (cropCenterX - videoCenterX) / videoRect.width;
        const offsetY = (cropCenterY - videoCenterY) / videoRect.height;
        
        // Вычисляем координаты с учетом масштаба и смещения
        const x = Math.max(0, Math.min(1, 0.5 + offsetX / currentScale));
        const y = Math.max(0, Math.min(1, 0.5 + offsetY / currentScale));
        
        // Размер области кропа с учетом масштаба
        const width = Math.min(1, cropRect.width / (videoRect.width * currentScale));
        const height = Math.min(1, cropRect.height / (videoRect.height * currentScale));

        const formData = new FormData();
        formData.append('video', videoFile);
        formData.append('cropData', JSON.stringify({
            x: x,
            y: y,
            width: width,
            height: height,
            currentTime: video.currentTime,
            scale: currentScale
        }));

        const initData = window.Telegram.WebApp.initDataUnsafe;
        if (!initData.user?.id) {
            throw new Error('Не удалось получить идентификатор чата');
        }
        formData.append('chatId', initData.user.id.toString());

        if (typeof tg.showProgress === 'function') {
            tg.showProgress();
        }

        const response = await fetch('/api/upload', {
            method: 'POST',
            body: formData
        });

        if (!response.ok) {
            const errorText = await response.text();
            throw new Error(errorText);
        }

        showStatusMessage('Видео готово ✅', 3000);
        
        setTimeout(() => {
            if (typeof tg.close === 'function') {
                tg.close();
            }
        }, 2000);

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